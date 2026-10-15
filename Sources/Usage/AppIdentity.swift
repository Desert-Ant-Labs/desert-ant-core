// The application identity a license grant names, derived per platform so
// hosts pass nothing:
//
//   Apple      Bundle.main.bundleIdentifier (e.g. com.acme.app), else process name
//   Linux      process name (server-side)
//   Android    the package name, via the host bridge (context.packageName)
//   WASI       the page's hostname (browser), else process.title (Node), server-side
//   other      "unknown"

import CStrings

#if canImport(Foundation) && !os(Android) && !os(WASI)
import Foundation
#elseif os(Android)
import CHostBridge
#elseif os(WASI)
import JavaScriptKit
#endif

import PlatformSupport

/// Read a host-provided string from a JS global that may be a string or a
/// zero-arg function returning one. `nil` when unset/empty or off WASI.
#if os(WASI)
private func jsHostString(_ name: String) -> String? {
    let value = jsHostValue(name)
    if let string = value.string, !string.isEmpty { return string }
    return nil
}

/// `globalThis[name]`, calling it when it is a function. An accessor or a
/// function that throws (say, one that needs a request context, called from a
/// retry timer) reads as unset instead of unwinding through the license client.
func jsHostValue(_ name: String) -> JSValue {
    let value = jsProperty(JSObject.global, name)
    guard let getter = value.function else { return value }
    return (try? getter.throws()) ?? .undefined
}
#endif

/// A host-provided application identity, overriding the auto-derived default.
/// On WASI reads `globalThis.__dalAppId` (string or function); elsewhere reads
/// the `DAL_APP_ID` environment variable. `nil` when unset.
public func hostProvidedAppId() -> String? {
#if os(WASI)
    return jsHostString("__dalAppId")
#else
    guard let value = environmentVariable("DAL_APP_ID") else { return nil }
    return value.isEmpty ? nil : value
#endif
}

#if os(WASI)
/// `process.env[name]` when the wasm core runs under Node; `nil` in a page.
func nodeEnvironmentVariable(_ name: String) -> String? {
    guard jsHostIsNode() else { return nil }
    return JSObject.global.process.object?.env.object?[name].string
}
#endif

/// A host-provided publishable API key. `DesertAnt.apiKey` set in code wins
/// (on Android, Kotlin's `DesertAnt.apiKey`, read through the host bridge);
/// otherwise on WASI reads `globalThis.__dalApiKey` (string or function), and
/// elsewhere reads the `DAL_API_KEY` environment variable. `nil` when unset.
public func hostProvidedApiKey() -> String? {
    if let key = trimmedKey(DesertAnt.apiKey) { return key }
#if os(Android)
    if let raw = host_api_key() {
        defer { host_free(raw) }
        if let key = trimmedKey(decodeCString(raw)) { return key }
    }
#endif
#if os(WASI)
    return trimmedKey(jsHostString("__dalApiKey"))
#else
    return trimmedKey(environmentVariable("DAL_API_KEY"))
#endif
}

/// `key` without surrounding whitespace, or nil when nothing is left. A key
/// read from a secret file often ends in a newline: the body tolerates it (the
/// endpoint trims), but an `Authorization` header with one is dropped or refused.
func trimmedKey(_ key: String?) -> String? {
    guard let key else { return nil }
    // `Character.isWhitespace`, not a list: "\r\n" is one Character in Swift.
    let trimmed = key.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed()
    return trimmed.isEmpty ? nil : String(trimmed)
}

/// A device id supplied by the host, for cases where the auto-generated,
/// persisted UUID doesn't fit, chiefly a server-side Node process (no per-device
/// storage; the "device" is the host's own notion). On WASI reads
/// `globalThis.__dalDeviceId` (string or function); elsewhere reads the
/// `DAL_DEVICE_ID` environment variable. `nil` when unset. Licensing counts the
/// install and does not read it yet.
public func hostProvidedDeviceId() -> String? {
#if os(WASI)
    return jsHostString("__dalDeviceId")
#else
    guard let value = environmentVariable("DAL_DEVICE_ID") else { return nil }
    return value.isEmpty ? nil : value
#endif
}

func hostProvidedLicenseEndpoint() -> String? {
#if os(WASI)
    if let value = jsHostString("__dalLicenseEndpoint") { return value }
    guard let value = nodeEnvironmentVariable("DAL_LICENSE_ENDPOINT"), !value.isEmpty else { return nil }
    return value
#else
    guard let value = environmentVariable("DAL_LICENSE_ENDPOINT") else { return nil }
    return value.isEmpty ? nil : value
#endif
}

/// The application identity for the current platform, sent as `app.id`.
public func defaultAppIdentifier() -> String {
#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
    if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty { return bundleID }
    return ProcessInfo.processInfo.processName
#elseif os(Linux)
    return ProcessInfo.processInfo.processName
#elseif os(Android)
    guard let raw = host_app_id() else { return "unknown" }
    defer { host_free(raw) }
    let value = decodeCString(raw)
    return value.isEmpty ? "unknown" : value
#elseif os(WASI)
    // Browser: the page hostname. Node: the process title.
    if let hostname = JSObject.global.location.object?.hostname.string, !hostname.isEmpty {
        return hostname
    }
    if let title = JSObject.global.process.object?.title.string, !title.isEmpty {
        return title
    }
    return "unknown"
#else
    return "unknown"
#endif
}
