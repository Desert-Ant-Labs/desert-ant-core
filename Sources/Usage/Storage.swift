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

/// A minimal string key/value store the turnstile persists into.
public protocol UsageStorage {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
}

// The generated device id is shared across SDKs in an app (one physical device);
// the re-emit state is namespaced per app key *and* device, so a multi-tenant
// server tracks a separate turnstile per end-user device.
let deviceIdKey = "ai.desertant.usage.deviceId"
private func stateKey(_ appKey: String, _ deviceId: String) -> String {
    "ai.desertant.usage.\(appKey).\(deviceId).state"
}
// The day of the last turnstile has a key of its own rather than a third field
// in `.state`: earlier core releases and the Kotlin port reset a `.state` that
// is not exactly two fields, losing the carry. Two SDKs in one app share these
// keys, so a newer one must not break an older one reading them.
private func emitDayKey(_ appKey: String, _ deviceId: String) -> String {
    "ai.desertant.usage.\(appKey).\(deviceId).emitDay"
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

    /// The turnstile state for an (app key, device) ("lastActiveAt,carryCallCount",
    /// plus the last emit day under its own key).
    func loadState(_ appKey: String, _ deviceId: String) -> UsageState {
        let emitDay = get(emitDayKey(appKey, deviceId)).flatMap { Int64($0) }
        guard let raw = get(stateKey(appKey, deviceId)) else { return UsageState(lastEmitDay: emitDay) }
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let last = Int64(parts[0]), let carry = Int(parts[1]) else {
            return UsageState(lastEmitDay: emitDay)
        }
        return UsageState(lastActiveAt: last, carryCallCount: carry, lastEmitDay: emitDay)
    }

    func saveState(_ state: UsageState, _ appKey: String, _ deviceId: String) {
        set(stateKey(appKey, deviceId), "\(state.lastActiveAt),\(state.carryCallCount)")
        // Only when it changed: every suspend and flush saves, but the day moves once a day.
        if let day = state.lastEmitDay.map(String.init), get(emitDayKey(appKey, deviceId)) != day {
            set(emitDayKey(appKey, deviceId), day)
        }
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
/// A Node host provides persistence by setting, before creating the client:
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
    // or a host store's error must not unwind through a flush that has already
    // taken its event off the queue. A failed read is unset; a failed write is
    // dropped, as reporting is best effort.
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
