import Testing
import PlatformSupport
@testable import Usage
#if os(WASI)
import JavaScriptKit
#endif

/// A switch a test flips while a transport or turnstile holds a reader of it.
private final class Switch: @unchecked Sendable { var on = false }

// Serialized: `DesertAnt.usageDisabled` and the host flags are process-wide.
@Suite(.serialized) struct UsageOptOutTests {
    @Test func offByDefault() {
        #expect(!DesertAnt.usageDisabled)
    }

    /// Under mise the environment flag is on as well, so on its own this proves
    /// little; `theHostGlobalIsRead` checks the switch with every host flag off.
    @Test func theInCodeSwitchTurnsUsageOff() {
        DesertAnt.usageDisabled = true
        defer { DesertAnt.usageDisabled = false }
        #expect(usageDisabled())
    }

    #if !os(WASI)
    /// The suites run with DAL_USAGE_DISABLED=1; `flagIsSet` covers the other values.
    @Test(.enabled(if: environmentVariable("DAL_USAGE_DISABLED") == "1"))
    func theEnvironmentFlagTurnsUsageOff() {
        #expect(usageDisabled())
    }
    #endif

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

    #if os(WASI)
    /// A page's consent banner sets `globalThis.__dalUsageDisabled` and clears it
    /// later; it is read the way the other host globals are.
    @Test func theHostGlobalIsRead() throws {
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
        #expect(!usageDisabled())

        // With no host flag, the in-code switch alone decides.
        DesertAnt.usageDisabled = true
        #expect(usageDisabled())
        DesertAnt.usageDisabled = false
        #expect(!usageDisabled())

        JSObject.global.__dalUsageDisabled = .boolean(true)
        #expect(usageDisabled())
        JSObject.global.__dalUsageDisabled = .boolean(false)
        #expect(!usageDisabled())
        JSObject.global.__dalUsageDisabled = .string("1")
        #expect(usageDisabled())
        for value in ["", "0", "false"] {
            JSObject.global.__dalUsageDisabled = .string(value)
            #expect(!usageDisabled(), "\(value) switched usage off")
        }
        // A number is not a flag, as with the context opt-out.
        JSObject.global.__dalUsageDisabled = .number(1)
        #expect(!usageDisabled())
        // A function, read on every call, as a consent manager may supply.
        let consent = Switch()
        JSObject.global.__dalUsageDisabled = .object(JSClosure { _ in .boolean(!consent.on) })
        #expect(usageDisabled())
        consent.on = true
        #expect(!usageDisabled())
        // A function that throws reads as unset instead of unwinding the client.
        let throwing = JSObject.global.Function.function!.new("throw new Error('no consent manager')")
        JSObject.global.__dalUsageDisabled = .object(throwing)
        #expect(!usageDisabled())
        // So does an accessor property whose getter throws.
        _ = JSObject.global.Function.function!.new("""
            Object.defineProperty(globalThis, "__dalUsageDisabled", { configurable: true, get() { throw new Error("blocked") } })
            """)()
        #expect(!usageDisabled())
        // With the global unreadable, the Node environment still applies.
        env.DAL_USAGE_DISABLED = .string("1")
        #expect(usageDisabled())
    }

    /// Under Node the wasm core also reads process.env, as tongue-node does.
    @Test func underNodeTheEnvironmentIsRead() throws {
        let env = try #require(JSObject.global.process.object?.env.object)
        let saved = env.DAL_USAGE_DISABLED
        defer {
            if saved.isUndefined { _ = JSObject.global.Reflect.object!.deleteProperty!(env, "DAL_USAGE_DISABLED") }
            else { env.DAL_USAGE_DISABLED = saved }
        }
        env.DAL_USAGE_DISABLED = .string("1")
        #expect(usageDisabled())
        env.DAL_USAGE_DISABLED = .string("false")
        #expect(!usageDisabled())
        env.DAL_USAGE_DISABLED = .string("0")
        #expect(!usageDisabled())
        env.DAL_USAGE_DISABLED = .string("true")
        #expect(usageDisabled())
    }
    #endif
}
