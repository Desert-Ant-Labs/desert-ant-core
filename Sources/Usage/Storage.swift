// Cross-session persistence for the usage turnstile — the device id and the
// re-emit state — handled internally so hosts wire no storage. `UsageStorage` is
// a tiny string key/value seam; `makeClient` uses the platform-native backend:
//
//   Apple / Linux  UserDefaults (Foundation)
//   Android        SharedPreferences, via the host bridge (CHostBridge)
//   WebAssembly    localStorage, or a host-injected globalThis.__dalUsageStore
//   other          in-memory (no persistence)
//
// Pass a `storage:` to `makeClient` to override, or drop to `createClient`/
// `ClientDeps` for full control (tests, custom hosts).

#if canImport(Foundation) && !os(Android) && !os(WASI)
import Foundation
#elseif os(Android)
import CHostBridge
#elseif os(WASI)
import JavaScriptKit
#endif

/// A minimal string key/value store the turnstile persists into.
public protocol UsageStorage {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
}

// The generated device id is shared across SDKs in an app (one physical device);
// the re-emit state is namespaced per app key *and* device, so a multi-tenant
// server tracks a separate turnstile per end-user device.
private let deviceIdKey = "ai.desertant.usage.deviceId"
private func stateKey(_ appKey: String, _ deviceId: String) -> String {
    "ai.desertant.usage.\(appKey).\(deviceId).state"
}

/// Resolve the device id for a client: an explicit one wins, then a host-provided
/// one (JS `__dalDeviceId`, e.g. server-side Node), then the generated+persisted
/// UUID from storage.
func resolveDeviceId(_ explicit: String?, _ storage: UsageStorage) -> String {
    explicit ?? hostProvidedDeviceId() ?? storage.persistentDeviceId()
}

extension UsageStorage {
    /// The stable per-install device id, generated and persisted on first use.
    public func persistentDeviceId() -> String {
        if let existing = get(deviceIdKey), !existing.isEmpty { return existing }
        let id = generateUUID()
        set(deviceIdKey, id)
        return id
    }

    /// The turnstile state for an (app key, device) ("lastActiveAt,carryCallCount").
    func loadState(_ appKey: String, _ deviceId: String) -> UsageState {
        guard let raw = get(stateKey(appKey, deviceId)) else { return UsageState() }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let last = Int64(parts[0]), let carry = Int(parts[1]) else {
            return UsageState()
        }
        return UsageState(lastActiveAt: last, carryCallCount: carry)
    }

    func saveState(_ state: UsageState, _ appKey: String, _ deviceId: String) {
        set(stateKey(appKey, deviceId), "\(state.lastActiveAt),\(state.carryCallCount)")
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
    let hasJSStore = JSObject.global.__dalUsageStore.object != nil
        || JSObject.global.localStorage.object != nil
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
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }
    public func set(_ key: String, _ value: String) {
        key.withCString { k in value.withCString { v in host_prefs_set(k, v) } }
    }
}
#endif

#if os(WASI)
/// WASI backend over a JS key/value object with Web-Storage-shaped
/// `getItem`/`setItem`. Prefers a host-injected `globalThis.__dalUsageStore`
/// (e.g. a Node server-side store), otherwise the browser's `localStorage`.
///
/// A Node host provides persistence by setting, before creating the client:
///   globalThis.__dalUsageStore = { getItem: (k) => string|null, setItem: (k, v) => {} }
public struct JSKeyValueStorage: UsageStorage {
    public init() {}
    // Resolved at access time so a host store installed after init still applies.
    private var storage: JSObject? {
        JSObject.global.__dalUsageStore.object ?? JSObject.global.localStorage.object
    }
    public func get(_ key: String) -> String? { storage?.getItem?(key).string }
    public func set(_ key: String, _ value: String) { _ = storage?.setItem?(key, value) }
}
#endif
