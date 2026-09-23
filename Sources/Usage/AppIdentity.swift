// The application identity used as the turnstile key, derived per platform so
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
/// flush timer) reads as unset: an exception unwinding through the client
/// would lose the event.
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

/// Whether usage tracking is switched off before any client is built.
///
/// Core deliberately leaves no untracked path through `Inference`, and this does
/// not weaken that for a shipped app: it exists because our own suites run on
/// networked CI, where every model load would otherwise post a real turnstile
/// event, and because a fire-and-forget send left in flight as a short-lived
/// process exits (a test runner, a CLI) is what raced Node's teardown into a
/// SIGSEGV. The wasm build does not read `DAL_USAGE_DISABLED`, in a page or
/// under Node, so it always tracks.
public func usageDisabled() -> Bool {
#if os(WASI)
    return false
#else
    guard let value = environmentVariable("DAL_USAGE_DISABLED") else { return false }
    return !value.isEmpty && value != "0"
#endif
}

/// A host-provided app version, overriding the bundle's own for the event
/// `context`. On WASI reads `globalThis.__dalAppVersion` (string or function),
/// then under Node `process.env.DAL_APP_VERSION`; elsewhere reads the
/// `DAL_APP_VERSION` environment variable. `nil` when unset.
/// The only appVersion a Linux, Android or wasm host sends.
func hostProvidedAppVersion() -> String? {
#if os(WASI)
    if let value = jsHostString("__dalAppVersion") { return value }
    guard let value = nodeEnvironmentVariable("DAL_APP_VERSION"), !value.isEmpty else { return nil }
    return value
#else
    guard let value = environmentVariable("DAL_APP_VERSION") else { return nil }
    return value.isEmpty ? nil : value
#endif
}

/// Whether the event `context` is switched off: `DesertAnt.sendsDeviceContext`
/// set to false in code, or the host flag: `globalThis.__dalUsageContextDisabled`
/// (a string, a boolean, or a function returning either) on WASI, then under
/// Node `process.env.DAL_USAGE_CONTEXT_DISABLED`, in the global-then-environment
/// order tongue-node's `hostString` uses; the
/// `DAL_USAGE_CONTEXT_DISABLED` environment variable elsewhere. A flag is a
/// string under `flagIsSet` or the boolean `true`; a number, 1 included, does
/// not opt out. Usage itself still reports; only the context goes.
func deviceContextDisabled() -> Bool {
    if !DesertAnt.sendsDeviceContext { return true }
#if os(WASI)
    let value = jsHostValue("__dalUsageContextDisabled")
    if value.boolean == true || flagIsSet(value.string) { return true }
    return flagIsSet(nodeEnvironmentVariable("DAL_USAGE_CONTEXT_DISABLED"))
#else
    return flagIsSet(environmentVariable("DAL_USAGE_CONTEXT_DISABLED"))
#endif
}

#if os(WASI)
/// `process.env[name]` when the wasm core runs under Node; `nil` in a page.
func nodeEnvironmentVariable(_ name: String) -> String? {
    guard jsHostIsNode() else { return nil }
    return JSObject.global.process.object?.env.object?[name].string
}
#endif

/// The truthiness rule for the context opt-outs: set, and not "", "0" or
/// "false". Only the context flags treat "false" as off: `usageDisabled()`
/// keeps the older rule, under which it disables, as `DAL_USAGE_DISABLED` does
/// in every port.
func flagIsSet(_ value: String?) -> Bool {
    guard let value else { return false }
    return value != "" && value != "0" && value != "false"
}

/// A host-provided publishable API key. `DesertAnt.apiKey` set in code wins;
/// otherwise on WASI reads `globalThis.__dalApiKey` (string or function), and
/// elsewhere reads the `DAL_API_KEY` environment variable. `nil` when unset.
public func hostProvidedApiKey() -> String? {
    if let key = trimmedKey(DesertAnt.apiKey) { return key }
#if os(WASI)
    return trimmedKey(jsHostString("__dalApiKey"))
#else
    return trimmedKey(environmentVariable("DAL_API_KEY"))
#endif
}

/// `key` without surrounding whitespace, or nil when nothing is left. A key
/// read from a secret file often ends in a newline: the body tolerated it (the
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
/// `DAL_DEVICE_ID` environment variable. `nil` when unset.
public func hostProvidedDeviceId() -> String? {
#if os(WASI)
    return jsHostString("__dalDeviceId")
#else
    guard let value = environmentVariable("DAL_DEVICE_ID") else { return nil }
    return value.isEmpty ? nil : value
#endif
}

/// A host-provided ingest endpoint, overriding the built-in one. On WASI reads
/// `globalThis.__dalIngestEndpoint` (string or function); elsewhere reads the
/// `DAL_INGEST_ENDPOINT` environment variable. `nil` when unset. Intended for
/// tests, local capture, and diagnostics — production uses the built-in default.
public func hostProvidedIngestEndpoint() -> String? {
#if os(WASI)
    return jsHostString("__dalIngestEndpoint")
#else
    guard let value = environmentVariable("DAL_INGEST_ENDPOINT") else { return nil }
    return value.isEmpty ? nil : value
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
