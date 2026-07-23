// A small async HTTP client that delegates to each platform's own networking,
// so no sockets or TLS are hand-rolled:
//
//   Apple / Linux  URLSession (Foundation / FoundationNetworking)
//   Android        the host (java.net/OkHttp) via CHostBridge
//   WebAssembly    the JS host's `fetch` (JavaScriptKit)
//
// The API is async because the native transports are (URLSession's `data(for:)`,
// `fetch`'s Promise); a synchronous call cannot bridge them on a single-threaded
// JS host anyway.

#if canImport(Foundation) && !os(WASI) && !os(Android)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#elseif os(WASI)
import JavaScriptKit
import JavaScriptEventLoop
#elseif os(Android)
import CHostBridge
#endif

/// A parsed HTTP response. `headers` preserves order and does not fold names.
public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [(name: String, value: String)]
    public let body: [UInt8]

    public init(status: Int, headers: [(name: String, value: String)], body: [UInt8]) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// The body decoded as UTF-8 (lossy: invalid bytes become U+FFFD).
    public var text: String { String(decoding: body, as: UTF8.self) }

    /// First value for `name`, matched case-insensitively (ASCII).
    public func header(_ name: String) -> String? {
        for pair in headers where asciiCaseEqual(pair.name, name) { return pair.value }
        return nil
    }
}

public enum HTTPClientError: Error, Sendable {
    case unsupportedPlatform
    case invalidURL
    /// The transport failed (network error, non-HTTP response, host bridge missing).
    case requestFailed(String)
}

/// Perform a `GET` and return the full response.
public func httpGET(_ url: String) async throws -> HTTPResponse {
    try await performHTTPRequest(method: "GET", url: url, body: nil, contentType: nil)
}

/// Perform a `POST` with a raw request body (default `application/json`).
public func httpPOST(_ url: String, body: [UInt8], contentType: String = "application/json") async throws -> HTTPResponse {
    try await performHTTPRequest(method: "POST", url: url, body: body, contentType: contentType)
}

/// Perform an arbitrary request. A `nil` body sends no entity.
public func httpRequest(method: String, url: String, body: [UInt8]? = nil, contentType: String? = nil) async throws -> HTTPResponse {
    try await performHTTPRequest(method: method, url: url, body: body, contentType: contentType)
}

// MARK: - Per-platform transport

#if canImport(Foundation) && !os(WASI) && !os(Android)

private func performHTTPRequest(method: String, url: String, body: [UInt8]?, contentType: String?) async throws -> HTTPResponse {
    guard let parsed = URL(string: url) else { throw HTTPClientError.invalidURL }
    var request = URLRequest(url: parsed)
    request.httpMethod = method
    if let body { request.httpBody = Data(body) }
    if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }

    let data: Data
    let response: URLResponse
    do {
        (data, response) = try await URLSession.shared.data(for: request)
    } catch {
        throw HTTPClientError.requestFailed("\(error)")
    }
    guard let http = response as? HTTPURLResponse else {
        throw HTTPClientError.requestFailed("non-HTTP response")
    }
    var headers: [(name: String, value: String)] = []
    for (key, value) in http.allHeaderFields {
        if let name = key as? String { headers.append((name, "\(value)")) }
    }
    return HTTPResponse(status: http.statusCode, headers: headers, body: [UInt8](data))
}

#elseif os(WASI)

// Opt-in verbose logging for the WASM HTTP client, enabled from JS by setting
// `globalThis.__dalHttpDebug = true`. Logs go to `console.log`.
private func httpDebugEnabled() -> Bool {
    JSObject.global.__dalHttpDebug.boolean ?? false
}

private func httpDebugLog(_ message: @autoclosure () -> String) {
    guard httpDebugEnabled() else { return }
    _ = JSObject.global.console.object?.log?("[DAL HTTP] \(message())".jsValue)
}

private func performHTTPRequest(method: String, url: String, body: [UInt8]?, contentType: String?) async throws -> HTTPResponse {
    httpDebugLog("\(method) \(url) (body: \(body?.count ?? 0) bytes, content-type: \(contentType ?? "none"))")
    if let body { httpDebugLog("request body: \(String(decoding: body, as: UTF8.self))") }
    let options = JSObject.global.Object.function!.new()
    options.method = method.jsValue
    if let contentType {
        let headers = JSObject.global.Object.function!.new()
        headers["Content-Type"] = contentType.jsValue
        options.headers = headers.jsValue
    }
    if let body { options.body = JSTypedArray<UInt8>(body).jsValue }

    guard let fetch = JSObject.global.fetch.function,
          let promise = JSPromise(from: fetch(url.jsValue, options.jsValue)) else {
        throw HTTPClientError.requestFailed("fetch(\(url))")
    }
    let value: JSValue
    do {
        value = try await promise.value
    } catch {
        httpDebugLog("fetch rejected for \(url): \(error)")
        throw error
    }
    guard let response = value.object else { throw HTTPClientError.requestFailed("no response") }
    let status = Int(response.status.number ?? 0)
    httpDebugLog("response \(status) for \(url)")

    // Content-Type is the only header consumers need; fetch's Headers object is
    // awkward to enumerate from Swift, so read just that one.
    var headers: [(name: String, value: String)] = []
    if let h = response.headers.object, let ct = h.get?("content-type").string {
        headers.append(("Content-Type", ct))
    }

    guard let bufferPromise = JSPromise(from: response.arrayBuffer!()) else {
        throw HTTPClientError.requestFailed("arrayBuffer(\(url))")
    }
    let u8 = JSObject.global.Uint8Array.function!.new(try await bufferPromise.value)
    guard let array = JSTypedArray<UInt8>(from: u8) else {
        throw HTTPClientError.requestFailed("bytes(\(url))")
    }
    let bytes = array.withUnsafeBytes { Array($0) }
    httpDebugLog("received \(bytes.count) bytes for \(url)")
    httpDebugLog("response body: \(String(decoding: bytes, as: UTF8.self))")
    return HTTPResponse(status: status, headers: headers, body: bytes)
}

#elseif os(Android)

private func performHTTPRequest(method: String, url: String, body: [UInt8]?, contentType: String?) async throws -> HTTPResponse {
    // The host (java.net/OkHttp) performs the request via CHostBridge and returns
    // a malloc'd buffer: 4-byte BE status, 4-byte BE body length, then the body.
    let raw: UnsafeMutablePointer<CChar>? = method.withCString { m in
        url.withCString { u in
            func call(_ ct: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
                if let body {
                    return body.withUnsafeBufferPointer { host_http_request(m, u, $0.baseAddress, Int32(body.count), ct) }
                }
                return host_http_request(m, u, nil, 0, ct)
            }
            if let contentType { return contentType.withCString { call($0) } }
            return call(nil)
        }
    }
    guard let raw else { throw HTTPClientError.requestFailed("host_http_request(\(url)) (no host)") }
    defer { host_free(raw) }
    let base = UnsafeRawPointer(raw).assumingMemoryBound(to: UInt8.self)
    let status = Int(base[0]) << 24 | Int(base[1]) << 16 | Int(base[2]) << 8 | Int(base[3])
    let length = Int(base[4]) << 24 | Int(base[5]) << 16 | Int(base[6]) << 8 | Int(base[7])
    let body = [UInt8](UnsafeBufferPointer(start: base + 8, count: length))
    return HTTPResponse(status: status, headers: [], body: body)
}

#else

private func performHTTPRequest(method: String, url: String, body: [UInt8]?, contentType: String?) async throws -> HTTPResponse {
    throw HTTPClientError.unsupportedPlatform
}

#endif

// MARK: - Helpers

/// Case-insensitive ASCII comparison without Foundation.
private func asciiCaseEqual(_ a: String, _ b: String) -> Bool {
    let au = a.utf8, bu = b.utf8
    guard au.count == bu.count else { return false }
    var i = au.startIndex, j = bu.startIndex
    while i != au.endIndex {
        if asciiLower(au[i]) != asciiLower(bu[j]) { return false }
        i = au.index(after: i); j = bu.index(after: j)
    }
    return true
}

private func asciiLower(_ c: UInt8) -> UInt8 { (c >= 0x41 && c <= 0x5A) ? c + 0x20 : c }
