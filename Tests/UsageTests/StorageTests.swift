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

    @Test func theInstallIdIsTheStoredOneWhenAnotherClientWroteAtTheSameMoment() {
        final class OverwrittenStorage: UsageStorage {
            var values: [String: String] = [:]
            func get(_ key: String) -> String? { values[key] }
            func set(_ key: String, _ value: String) { values[key] = "written-by-another-client" }
        }
        let store = OverwrittenStorage()
        #expect(store.persistentDeviceId() == "written-by-another-client")
        #expect(store.persistentDeviceId() == "written-by-another-client")
    }

    @Test func theInstallIdIsTheNewOneWhenTheStoreDropsTheWrite() {
        struct DroppingStorage: UsageStorage {
            func get(_ key: String) -> String? { nil }
            func set(_ key: String, _ value: String) {}
        }
        #expect(DroppingStorage().persistentDeviceId().count == 36)
    }

    #if os(Linux)
    @Test func userDefaultsWritesToDiskAndSeesAnotherWritersValue() throws {
        let suite = "dal.usage.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStorage(defaults: defaults)
        #expect(store.get("theirs") == nil)
        store.set("mine", "1")

        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config"
        let file = URL(fileURLWithPath: config).appendingPathComponent(suite + ".plist")
        var onDisk = try #require(
            PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        #expect(onDisk["mine"] as? String == "1")

        onDisk["theirs"] = "2"
        try PropertyListSerialization.data(fromPropertyList: onDisk, format: .xml, options: 0).write(to: file)
        #expect(store.get("theirs") == "2")
    }
    #endif

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
        store.saveLicense(StoredLicense(token: "t"), "acme")
        #expect(store.loadLicense("acme") == StoredLicense())
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
