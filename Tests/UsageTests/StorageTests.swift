import Testing
@testable import Usage
#if canImport(Foundation) && !os(Android) && !os(WASI)
import Foundation
#endif
#if os(WASI)
import JavaScriptKit
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

    #if canImport(Foundation) && !os(Android) && !os(WASI)
    @Test func userDefaultsPersists() throws {
        let suite = "dal.usage.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsStorage(defaults: defaults)
        #expect(store.get("x") == nil)
        store.set("x", "y")
        #expect(store.get("x") == "y")
        // The install id persists through it.
        let id = store.persistentDeviceId()
        #expect(UserDefaultsStorage(defaults: defaults).persistentDeviceId() == id)
    }
    #endif

    #if os(WASI)
    @Test func aJSStoreRoundTripsAndKeepsTheInstallId() {
        let make = JSObject.global.Function.function!.new("""
            return { m: new Map(),
                     getItem(k) { return this.m.has(k) ? this.m.get(k) : null },
                     setItem(k, v) { this.m.set(k, String(v)) } }
            """)
        let store = JSKeyValueStorage(object: make().object!)
        #expect(store.get("missing") == nil)
        store.set("k", "v")
        #expect(store.get("k") == "v")
        let id = store.persistentDeviceId()
        #expect(store.persistentDeviceId() == id)
    }

    @Test func aThrowingJSStoreReadsAsUnsetAndDropsTheWrite() {
        let throwing = JSObject.global.Function.function!.new("k", "v", "throw new Error('quota')")
        let object = JSObject.global.Object.function!.new()
        object.getItem = .object(throwing)
        object.setItem = .object(throwing)
        let store = JSKeyValueStorage(object: object)
        store.set("k", "v")
        #expect(store.get("k") == nil)
        store.saveLicense(StoredLicense(token: "t"), "acme", "emo")
        #expect(store.loadLicense("acme", "emo") == StoredLicense())
    }

    @Test func aPropertyWhoseGetterThrowsReadsAsAbsent() {
        let make = JSObject.global.Function.function!.new("""
            const o = {}; Object.defineProperty(o, "localStorage", { get() { throw new Error("SecurityError") } }); return o
            """)
        #expect(jsProperty(make().object!, "localStorage").isUndefined)
    }
    #endif
}

struct AppIdentityTests {
    @Test func returnsNonEmptyIdentity() {
        // On macOS this is the bundle id or the test process name.
        #expect(!defaultAppIdentifier().isEmpty)
    }
}
