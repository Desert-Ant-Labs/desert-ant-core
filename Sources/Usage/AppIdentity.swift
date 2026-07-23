// The application identity used as the turnstile key, derived per platform so
// hosts pass nothing:
//
//   Apple      Bundle.main.bundleIdentifier (e.g. com.acme.app), else process name
//   Linux      process name (server-side)
//   Android    the package name, via the host bridge (context.packageName)
//   WASI       the page's hostname (browser), else process.title (Node), server-side
//   other      "unknown"

#if canImport(Foundation) && !os(Android) && !os(WASI)
import Foundation
#elseif os(Android)
import CHostBridge
#elseif os(WASI)
import JavaScriptKit
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#endif

/// Read a host-provided string from a JS global that may be a string or a
/// zero-arg function returning one. `nil` when unset/empty or off WASI.
#if os(WASI)
private func jsHostString(_ name: String) -> String? {
    let value = JSObject.global[name]
    if let string = value.string, !string.isEmpty { return string }
    if let getter = value.function, let string = getter().string, !string.isEmpty { return string }
    return nil
}
#endif

/// A host-provided application identity, overriding the auto-derived default.
/// On WASI reads `globalThis.__dalAppId` (string or function); elsewhere reads
/// the `DAL_APP_ID` environment variable. `nil` when unset.
public func hostProvidedAppId() -> String? {
#if os(WASI)
    return jsHostString("__dalAppId")
#else
    guard let raw = getenv("DAL_APP_ID") else { return nil }
    let value = String(cString: raw)
    return value.isEmpty ? nil : value
#endif
}

/// A host-provided publishable API key. On WASI reads `globalThis.__dalApiKey`
/// (string or function); elsewhere reads the `DAL_API_KEY` environment
/// variable. `nil` when unset.
public func hostProvidedApiKey() -> String? {
#if os(WASI)
    return jsHostString("__dalApiKey")
#else
    guard let raw = getenv("DAL_API_KEY") else { return nil }
    let value = String(cString: raw)
    return value.isEmpty ? nil : value
#endif
}

/// A device id supplied by the JS host, for cases where the auto-generated,
/// persisted UUID doesn't fit — chiefly a server-side Node process (no per-device
/// storage; the "device" is the host's own notion). `globalThis.__dalDeviceId`
/// may be a string or a function returning one. `nil` off WASI or when unset.
public func hostProvidedDeviceId() -> String? {
#if os(WASI)
    return jsHostString("__dalDeviceId")
#else
    return nil
#endif
}

/// The application identity for the current platform. Used as the wire key.
public func defaultAppIdentifier() -> String {
#if os(macOS) || os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
    if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty { return bundleID }
    return ProcessInfo.processInfo.processName
#elseif os(Linux)
    return ProcessInfo.processInfo.processName
#elseif os(Android)
    guard let raw = host_app_id() else { return "unknown" }
    defer { host_free(raw) }
    let value = String(cString: raw)
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
