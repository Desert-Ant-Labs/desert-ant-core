import Testing
import PlatformSupport
@testable import Usage
#if os(WASI)
import JavaScriptKit
#endif

/// A switch a test flips while a transport or turnstile holds a reader of it.
private final class Switch: @unchecked Sendable { var on = false }

// Serialized: the host flags are process-wide.
@Suite(.serialized) struct UsageOptOutTests {
    #if !os(WASI)
    /// The suites run with DAL_USAGE_DISABLED=1 (mise.toml), and a test process
    /// honors it in either configuration: test:swift runs release, the Windows
    /// job debug.
    @Test(.enabled(if: environmentVariable("DAL_USAGE_DISABLED") == "1"))
    func theEnvironmentFlagIsHonoredInATestProcess() {
        #expect(usageDisabled())
    }
    #endif

    #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
    /// What lets a release test run honor the switch: Swift Testing is loaded.
    @Test func thisProcessIsRecognizedAsATestProcess() {
        #expect(testFrameworkIsLoaded)
    }
    #endif

    /// `flagIsSet` decides for the test switch. A release build outside a test
    /// process, the one a customer ships, ignores every value.
    @Test func theTestSwitchIsIgnoredByAShippedBuild() {
        for value in ["1", "true", "yes"] {
            #expect(testSwitchIsSet(value, inTestProcess: true), "\(value) did not switch usage off")
            #if DEBUG
            #expect(testSwitchIsSet(value, inTestProcess: false), "a debug build ignored \(value)")
            #else
            #expect(!testSwitchIsSet(value, inTestProcess: false), "a shipped build honored \(value)")
            #endif
        }
        for value in [nil, "", "0", "false"] as [String?] {
            #expect(!testSwitchIsSet(value, inTestProcess: true), "\(value ?? "nil") switched usage off")
        }
    }

    /// The transport reads the switch per send, so an event queued before a
    /// consent was withdrawn is dropped, and one queued after it was given goes.
    @Test func theTransportReadsTheSwitchPerSend() async {
        let registry = InflightSends()
        let off = Switch()
        // Nothing listens on port 1, so a send that does go out fails at once.
        let send = makeSend(endpoint: "http://127.0.0.1:1/ingest", registry: registry, disabled: { off.on })
        let body = IngestBody(sentAt: "t", events: [IngestEvent(deviceId: "d")])

        off.on = true
        send(body, SendOptions())
        send(body, SendOptions(beacon: true))
        #expect(registry.registeredTotal == 0, "a switched-off transport sent")

        off.on = false
        send(body, SendOptions())
        #expect(registry.registeredTotal == 1, "clearing the switch did not let the next send go")

        off.on = true
        send(body, SendOptions())
        #expect(registry.registeredTotal == 1, "setting the switch again did not stop the next send")
        for task in registry.drain() { await task.value }
    }

    /// The client itself holds while the switch is on: a flush, a load or a
    /// suspend neither stores nor sends, and what it held goes out once the
    /// switch is cleared. This is what a host's own `makeClient` client gets.
    @Test func theClientHoldsWhileSwitchedOff() {
        let off = Switch()
        var state = UsageState()
        var saves = 0
        var sent: [IngestBody] = []
        let client = UsageClient(ClientDeps(
            deviceId: "d", platform: "test", now: { 1_000_000_000_000 },
            loadState: { state }, saveState: { state = $0; saves += 1 },
            send: { body, _ in sent.append(body) },
            disabled: { off.on }
        ))
        client.start()
        client.recordCall()
        off.on = true
        let before = saves
        client.recordCall()
        client.flush()
        client.suspend()
        client.load()
        client.carryUnsent()
        #expect(sent.isEmpty, "a switched-off client sent")
        #expect(saves == before, "a switched-off client wrote its store")
        off.on = false
        client.flush()
        #expect(sent.count == 1)
        #expect(sent.first?.events.first?.callCount == 1, "the held call was lost, or one made while off counted")
    }

    #if os(WASI)
    /// A page's consent banner sets `globalThis.__dalUsageDisabled` and clears it
    /// later; it is read the way the other host globals are.
    @Test func aPageReadsTheHostGlobal() throws {
        let env = try #require(JSObject.global.process.object?.env.object)
        let savedEnv = env.DAL_USAGE_DISABLED
        let reflect = JSObject.global.Reflect.object!
        defer {
            _ = reflect.deleteProperty!(JSObject.global, "__dalUsageDisabled")
            if savedEnv.isUndefined { _ = reflect.deleteProperty!(env, "DAL_USAGE_DISABLED") }
            else { env.DAL_USAGE_DISABLED = savedEnv }
        }
        // The suite runs with DAL_USAGE_DISABLED=1 under Node; out of the way,
        // so the global alone decides.
        _ = reflect.deleteProperty!(env, "DAL_USAGE_DISABLED")
        #expect(!usageDisabled(inPage: true))

        JSObject.global.__dalUsageDisabled = .boolean(true)
        #expect(usageDisabled(inPage: true))
        JSObject.global.__dalUsageDisabled = .boolean(false)
        #expect(!usageDisabled(inPage: true))
        JSObject.global.__dalUsageDisabled = .string("1")
        #expect(usageDisabled(inPage: true))
        for value in ["", "0", "false"] {
            JSObject.global.__dalUsageDisabled = .string(value)
            #expect(!usageDisabled(inPage: true), "\(value) switched usage off")
        }
        // A finite non-zero number opts out, failing closed, as older tongue-node
        // did; 0, NaN and infinity do not.
        for number in [1.0, -1, 0.5] {
            JSObject.global.__dalUsageDisabled = .number(number)
            #expect(usageDisabled(inPage: true), "\(number) did not switch usage off")
        }
        for number in [0.0, .nan, .infinity] {
            JSObject.global.__dalUsageDisabled = .number(number)
            #expect(!usageDisabled(inPage: true), "\(number) switched usage off")
        }
        // A function, read on every call, as a consent manager may supply.
        let consent = Switch()
        JSObject.global.__dalUsageDisabled = .object(JSClosure { _ in .boolean(!consent.on) })
        #expect(usageDisabled(inPage: true))
        consent.on = true
        #expect(!usageDisabled(inPage: true))
        // A function that throws reads as unset instead of unwinding the client.
        let throwing = JSObject.global.Function.function!.new("throw new Error('no consent manager')")
        JSObject.global.__dalUsageDisabled = .object(throwing)
        #expect(!usageDisabled(inPage: true))
        // So does an accessor property whose getter throws.
        _ = JSObject.global.Function.function!.new("""
            Object.defineProperty(globalThis, "__dalUsageDisabled", { configurable: true, get() { throw new Error("blocked") } })
            """)()
        #expect(!usageDisabled(inPage: true))
    }

    /// The same wasm binary under Node is a server, and a server has no opt-out:
    /// the global a page would set is ignored there. This suite runs under Node,
    /// so the unparameterized reader must take the server path too.
    @Test func underNodeTheHostGlobalIsIgnored() throws {
        let env = try #require(JSObject.global.process.object?.env.object)
        let savedEnv = env.DAL_USAGE_DISABLED
        let reflect = JSObject.global.Reflect.object!
        defer {
            _ = reflect.deleteProperty!(JSObject.global, "__dalUsageDisabled")
            if savedEnv.isUndefined { _ = reflect.deleteProperty!(env, "DAL_USAGE_DISABLED") }
            else { env.DAL_USAGE_DISABLED = savedEnv }
        }
        _ = reflect.deleteProperty!(env, "DAL_USAGE_DISABLED")
        #expect(jsHostIsNode())
        #expect(defaultPlatform == "server")
        for value: JSValue in [.boolean(true), .string("1"), .number(1)] {
            JSObject.global.__dalUsageDisabled = value
            #expect(!usageDisabled(), "Node honored the page's global")
            #expect(!usageDisabled(inPage: false), "Node honored the page's global")
        }
    }

    /// Under Node, process.env.DAL_USAGE_DISABLED is the test switch, as the
    /// environment variable is natively. test:wasi builds debug, so it is
    /// honored here; the release wasm the packages ship has no test framework
    /// loaded and ignores it (`theTestSwitchIsIgnoredByAShippedBuild`).
    @Test func underNodeTheEnvironmentIsTheTestSwitch() throws {
        let env = try #require(JSObject.global.process.object?.env.object)
        let saved = env.DAL_USAGE_DISABLED
        defer {
            if saved.isUndefined { _ = JSObject.global.Reflect.object!.deleteProperty!(env, "DAL_USAGE_DISABLED") }
            else { env.DAL_USAGE_DISABLED = saved }
        }
        for value in ["1", "true"] {
            env.DAL_USAGE_DISABLED = .string(value)
            #if DEBUG
            #expect(usageDisabled())
            #else
            #expect(!usageDisabled(), "a release wasm build honored DAL_USAGE_DISABLED")
            #endif
        }
        for value in ["false", "0"] {
            env.DAL_USAGE_DISABLED = .string(value)
            #expect(!usageDisabled())
        }
    }

    /// Release wasm under Node, in this repo's tests, is kept off the real
    /// ingest by `DAL_INGEST_ENDPOINT` in the environment, since the debug
    /// switch does not reach it. The global still wins, as it does in a page.
    @Test func underNodeTheEnvironmentRedirectsTheIngest() throws {
        let env = try #require(JSObject.global.process.object?.env.object)
        let saved = env.DAL_INGEST_ENDPOINT
        let reflect = JSObject.global.Reflect.object!
        defer {
            _ = reflect.deleteProperty!(JSObject.global, "__dalIngestEndpoint")
            if saved.isUndefined { _ = reflect.deleteProperty!(env, "DAL_INGEST_ENDPOINT") }
            else { env.DAL_INGEST_ENDPOINT = saved }
        }
        _ = reflect.deleteProperty!(env, "DAL_INGEST_ENDPOINT")
        #expect(hostProvidedIngestEndpoint() == nil)
        env.DAL_INGEST_ENDPOINT = .string("http://127.0.0.1:9/ingest")
        #expect(hostProvidedIngestEndpoint() == "http://127.0.0.1:9/ingest")
        JSObject.global.__dalIngestEndpoint = .string("http://127.0.0.1:10/ingest")
        #expect(hostProvidedIngestEndpoint() == "http://127.0.0.1:10/ingest")
    }
    #endif
}
