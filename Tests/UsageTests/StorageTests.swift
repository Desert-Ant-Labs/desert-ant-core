import Testing
@testable import Usage
#if canImport(Foundation) && !os(Android) && !os(WASI)
import Foundation
#endif

struct StorageTests {
    @Test func inMemoryGetSet() {
        let store = InMemoryStorage()
        #expect(store.get("k") == nil)
        store.set("k", "v")
        #expect(store.get("k") == "v")
    }

    @Test func deviceIdIsGeneratedOnceAndStable() {
        let store = InMemoryStorage()
        let id = store.persistentDeviceId()
        #expect(id.count == 36)                       // a UUID
        #expect(store.persistentDeviceId() == id)     // stable across calls
    }

    @Test func explicitDeviceIdWinsOverGenerated() {
        let store = InMemoryStorage()
        // An explicit id (e.g. a server-side Node process supplies its own) is used
        // as-is; otherwise it falls back to the generated, persisted UUID.
        #expect(resolveDeviceId("server-device-1", store) == "server-device-1")
        let generated = resolveDeviceId(nil, store)
        #expect(generated.count == 36)
        #expect(resolveDeviceId(nil, store) == generated)   // stable
    }

    @Test func stateRoundTripsPerKeyAndDevice() {
        let store = InMemoryStorage()
        #expect(store.loadState("acme", "dev-1") == UsageState())   // unset -> default
        store.saveState(UsageState(lastActiveAt: 123, carryCallCount: 4), "acme", "dev-1")
        #expect(store.loadState("acme", "dev-1") == UsageState(lastActiveAt: 123, carryCallCount: 4))
        #expect(store.loadState("acme", "dev-2") == UsageState())   // namespaced per device
        #expect(store.loadState("other", "dev-1") == UsageState())  // and per key
    }

    #if canImport(Foundation) && !os(Android) && !os(WASI)
    @Test func userDefaultsPersists() throws {
        let suite = "dal.usage.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsStorage(defaults: defaults)
        #expect(store.get("x") == nil)
        store.set("x", "y")
        #expect(store.get("x") == "y")
        // deviceId + state helpers persist through it.
        let id = store.persistentDeviceId()
        #expect(UserDefaultsStorage(defaults: defaults).persistentDeviceId() == id)
    }
    #endif
}

struct AppIdentityTests {
    @Test func returnsNonEmptyIdentity() {
        // On macOS this is the bundle id or the test process name.
        #expect(!defaultAppIdentifier().isEmpty)
    }
}
