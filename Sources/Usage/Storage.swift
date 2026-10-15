// Persistence for licensing (the install id and the stored licenses), handled
// internally so hosts wire no storage:
//
//   Apple / Linux  UserDefaults (Foundation)
//   Android        SharedPreferences, via the host bridge (CHostBridge)
//   WebAssembly    localStorage, or a host-injected globalThis.__dalUsageStore
//   other          in-memory (no persistence)

import CStrings

#if canImport(Foundation) && !os(Android) && !os(WASI)
import Foundation
#elseif os(Android)
import CHostBridge
#elseif os(WASI)
import JavaScriptKit
#endif

#if os(WASI)
/// Whether the JS host is Node (rather than a browser or worker).
func jsHostIsNode() -> Bool {
    JSObject.global.process.object?.versions.object?.node.string != nil
}
#endif

/// A minimal string key/value store the SDK persists into.
public protocol UsageStorage {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
}

// The install id licensing sends. The key keeps its old name so an existing install keeps its id.
let deviceIdKey = "ai.desertant.usage.deviceId"

extension UsageStorage {
    /// The stable per-install device id, generated and persisted on first use.
    public func persistentDeviceId() -> String {
        if let existing = get(deviceIdKey), !existing.isEmpty { return existing }
        let id = generateUUID()
        set(deviceIdKey, id)
        return id
    }
}

/// The platform's native storage.
public func defaultStorage() -> UsageStorage {
#if canImport(Foundation) && !os(Android) && !os(WASI)
    return UserDefaultsStorage()
#elseif os(Android)
    return HostPreferencesStorage()
#elseif os(WASI)
    // Prefer a host-injected store (globalThis.__dalUsageStore, e.g. server-side
    // Node), then the browser's localStorage; otherwise in-memory.
    //
    // Node is checked first and never probed for localStorage: Node exposes a
    // `localStorage` global that is unusable without --localstorage-file, and
    // merely touching it prints an ExperimentalWarning - which every consumer of
    // the server-side build would see on load, for a store we cannot use anyway.
    let hasJSStore = jsProperty(JSObject.global, "__dalUsageStore").object != nil
        || (!jsHostIsNode() && jsProperty(JSObject.global, "localStorage").object != nil)
    return hasJSStore ? JSKeyValueStorage() : InMemoryStorage()
#else
    return InMemoryStorage()
#endif
}

/// No persistence; also handy for tests.
public final class InMemoryStorage: UsageStorage {
    private var values: [String: String]
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func get(_ key: String) -> String? { values[key] }
    public func set(_ key: String, _ value: String) { values[key] = value }
}

#if canImport(Foundation) && !os(Android) && !os(WASI)
/// Apple/Linux backend over `UserDefaults`.
public struct UserDefaultsStorage: UsageStorage {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func get(_ key: String) -> String? { defaults.string(forKey: key) }
    public func set(_ key: String, _ value: String) { defaults.set(value, forKey: key) }
}
#endif

#if os(Android)
/// Android backend: SharedPreferences via the CHostBridge `host_prefs_*`
/// callbacks (installed by the JNI harness). If the host has not installed them,
/// nothing persists.
public struct HostPreferencesStorage: UsageStorage {
    public init() {}
    public func get(_ key: String) -> String? {
        guard let raw = key.withCString({ host_prefs_get($0) }) else { return nil }
        defer { host_free(raw) }
        let value = decodeCString(raw)
        return value.isEmpty ? nil : value
    }
    public func set(_ key: String, _ value: String) {
        key.withCString { k in value.withCString { v in host_prefs_set(k, v) } }
    }
}
#endif

#if os(WASI)
/// `object[name]`, read through `Reflect.get` in the throwing form. The
/// `localStorage` getter itself throws a SecurityError in a sandboxed or
/// storage-blocked frame; that reads as absent instead of unwinding the client.
func jsProperty(_ object: JSObject, _ name: String) -> JSValue {
    guard let reflect = JSObject.global.Reflect.object else { return .undefined }
    return (try? reflect.throwing.get?(object, name)) ?? .undefined
}

/// WASI backend over a JS key/value object with Web-Storage-shaped
/// `getItem`/`setItem`. Prefers a host-injected `globalThis.__dalUsageStore`
/// (e.g. a Node server-side store), otherwise the browser's `localStorage`.
///
/// A Node host provides persistence by setting, before the first model loads:
///   globalThis.__dalUsageStore = { getItem: (k) => string|null, setItem: (k, v) => {} }
public struct JSKeyValueStorage: UsageStorage {
    private let fixed: JSObject?
    public init() { fixed = nil }
    /// A store over `object` alone, for tests: the global ones are process-wide.
    init(object: JSObject) { fixed = object }
    // Resolved at access time so a host store installed after init still applies.
    private var storage: JSObject? {
        if let fixed { return fixed }
        if let injected = jsProperty(JSObject.global, "__dalUsageStore").object { return injected }
        return jsHostIsNode() ? nil : jsProperty(JSObject.global, "localStorage").object
    }
    // Through the throwing form: a full origin's `setItem` (QuotaExceededError)
    // or a host store's error must not unwind through the license client. A
    // failed read is unset; a failed write is dropped.
    public func get(_ key: String) -> String? {
        guard let storage else { return nil }
        return (try? storage.throwing.getItem?(key))?.string
    }
    public func set(_ key: String, _ value: String) {
        guard let storage else { return }
        _ = try? storage.throwing.setItem?(key, value)
    }
}
#endif
