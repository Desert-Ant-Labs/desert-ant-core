import Testing
@testable import Usage

// A test harness: in-memory persisted state, a controllable clock, and a sink
// that captures every sent body.
private final class Harness {
    var state: UsageState
    var clock: Int64 = 1_000_000_000_000
    var sent: [(body: IngestBody, opts: SendOptions, at: Int64)] = []
    private(set) var client: UsageClient
    private let makeClient: () -> UsageClient

    init(_ initial: UsageState = UsageState(), callCount: (() -> Int)? = nil, windowMs: Int64 = dayMs, emitIntervalMs: Int64 = 0, keyInBody: Bool = true) {
        self.state = initial
        // Captured by reference through the closures below.
        var boxRef: Harness!
        let factory = {
            UsageClient(ClientDeps(
                deviceId: "dev-1",
                key: "dal_test",
                keyInBody: keyInBody,
                platform: "test",
                callCount: callCount,
                windowMs: windowMs,
                emitIntervalMs: emitIntervalMs,
                now: { boxRef.clock },
                loadState: { boxRef.state },
                saveState: { boxRef.state = $0 },
                send: { body, opts in boxRef.sent.append((body, opts, boxRef.clock)) }
            ))
        }
        self.makeClient = factory
        self.client = factory()
        boxRef = self
    }

    /// A new process over the same persisted state: the in-memory session
    /// (whether this launch has emitted) starts over, as it does on a relaunch.
    func relaunch() { client = makeClient() }

    var events: [IngestEvent] { sent.flatMap { $0.body.events } }
    func advance(_ ms: Int64) { clock += ms }
}

struct UsageClientTests {
    @Test func startEmitsWhenWindowElapsed() {
        let h = Harness(UsageState(lastActiveAt: 0))
        h.client.start()
        h.client.flush()

        #expect(h.sent.count == 1)
        let ev = h.events[0]
        #expect(ev.name == "load")
        #expect(ev.deviceId == "dev-1")
        #expect(h.sent[0].body.platform == "test")
        #expect(h.sent[0].body.key == "dal_test")
        #expect(h.state.lastActiveAt > 0)
    }

    /// Where the transport sets an `Authorization` header, the key must not also
    /// ride the body: two copies of one secret in one request. The header itself is
    /// proved on the wire in `HTTPTests`.
    @Test func keyOmitsTheBodyWhereTheTransportSendsAHeader() {
        let h = Harness(UsageState(lastActiveAt: 0), keyInBody: false)
        h.client.start()
        h.client.flush()

        #expect(h.sent.count == 1)
        #expect(h.sent[0].body.key == nil)
        let json = try? buildBody(h.sent[0].body)
        #expect(json?.contains("dal_test") == false)
    }

    /// The default client's own decision: the platform tag it reports and whether
    /// the key rides the body. Every other test here builds `ClientDeps` by hand,
    /// so a hardcoded platform tag or a wrong `keyInBody` inside `makeClient` would
    /// go unnoticed. The header half of the pairing is proved on the wire in
    /// `HTTPTests`; what this pins is that the body half matches it.
    @Test func theDefaultClientTagsThePlatformAndPlacesTheKeyOnce() {
        var sent: [IngestBody] = []
        let client = makeClient(
            key: "dal_test",
            deviceId: "host-device",
            context: { nil },
            storage: InMemoryStorage(),
            send: { body, _ in sent.append(body) },
            disabled: { false }
        )
        client.start()
        client.recordCall()
        client.flush()

        #expect(sent.count == 1)
        let body = sent[0]
        #expect(["ios", "android", "web", "server"].contains(body.platform))
        #if os(Android)
        #expect(body.platform == "android")
        #elseif os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
        #expect(body.platform == "ios")
        #elseif os(WASI)
        // test:wasi runs this binary under Node; a page would report "web".
        #expect(body.platform == "server")
        #else
        #expect(body.platform == "server")
        #endif
        // Where the build cannot set an `Authorization` header, the key must ride
        // the body instead, or the event arrives unattributed. The wasm build (its
        // unload flush is a header-less `sendBeacon`) is that case. The header half
        // of this pairing is proved on the wire in `HTTPTests`.
        #if os(WASI)
        #expect(body.key == "dal_test")
        #else
        #expect(body.key == nil)
        #endif
    }

    @Test func startDoesNotEmitWithinWindow() {
        let now: Int64 = 1_000_000_000_000
        let h = Harness(UsageState(lastActiveAt: now - (dayMs - 1), lastEmitDay: utcDay(now)))
        h.client.start()
        h.client.flush()
        #expect(h.sent.isEmpty)
    }

    @Test func recordCallAccumulatesIntoLoad() {
        let h = Harness(UsageState(lastActiveAt: 0))
        h.client.start()
        h.client.recordCall(2)
        h.client.recordCall()
        h.client.flush()
        #expect(h.events[0].callCount == 3)
    }

    @Test func throttledSessionCallsCarryToNextEmit() {
        let now: Int64 = 1_000_000_000_000
        let h = Harness(UsageState(lastActiveAt: now - 1000, lastEmitDay: utcDay(now)))
        h.client.start()
        h.client.recordCall(5)
        h.client.flush()
        #expect(h.sent.isEmpty)
        #expect(h.state.carryCallCount == 5)

        h.advance(dayMs)
        h.client.start()
        h.client.recordCall(2)
        h.client.flush()
        #expect(h.sent.count == 1)
        #expect(h.events[0].callCount == 7)
        #expect(h.state.carryCallCount == 0)
    }

    @Test func lateCallsRideADeltaLoad() {
        let h = Harness(UsageState(lastActiveAt: 0))
        h.client.start()
        h.client.recordCall(1)
        h.client.flush()
        h.client.recordCall(4)
        h.client.flush(SendOptions(beacon: true))

        #expect(h.events.count == 2)
        #expect(h.events[0].callCount == 1)
        #expect(h.events[1].callCount == 4)
        #expect(h.sent[1].opts.beacon == true)
    }

    @Test func serverCoalescesDeltaLoadsWithinInterval() {
        let h = Harness(UsageState(lastActiveAt: 0), emitIntervalMs: hourMs)
        h.client.start()
        h.client.recordCall(1)
        h.client.flush() // turnstile
        #expect(h.sent.count == 1)
        #expect(h.events[0].callCount == 1)

        // Flushes within the hour are held, not sent.
        for _ in 0..<3 {
            h.advance(60_000)
            h.client.recordCall(2)
            h.client.flush()
        }
        #expect(h.sent.count == 1)
        #expect(h.state.carryCallCount == 6)

        // Past the hour: one delta carrying everything held.
        h.advance(hourMs)
        h.client.recordCall(2)
        h.client.flush()
        #expect(h.sent.count == 2)
        #expect(h.events[1].callCount == 8)
        #expect(h.state.carryCallCount == 0)
    }

    @Test func beaconFlushesHeldDeltasImmediately() {
        let h = Harness(UsageState(lastActiveAt: 0), emitIntervalMs: hourMs)
        h.client.start()
        h.client.flush()
        h.advance(60_000)
        h.client.recordCall(5)
        h.client.flush() // held within the hour
        #expect(h.sent.count == 1)

        h.client.recordCall(2)
        h.client.flush(SendOptions(beacon: true)) // unload drains held + new
        #expect(h.sent.count == 2)
        #expect(h.events[1].callCount == 7)
        #expect(h.sent[1].opts.beacon == true)
    }

    @Test func manualLoadBypassesWindow() {
        let now: Int64 = 1_000_000_000_000
        let h = Harness(UsageState(lastActiveAt: now - 1000, lastEmitDay: utcDay(now) - 1))
        h.client.load()
        #expect(h.sent.count == 1)
        #expect(h.events[0].name == "load")
        #expect(h.state.lastEmitDay == utcDay(now))
    }

    @Test func callCountProviderOverridesRecordCall() {
        let h = Harness(UsageState(lastActiveAt: 0), callCount: { 42 })
        h.client.start()
        h.client.recordCall(7)
        h.client.flush()
        #expect(h.events[0].callCount == 42)
    }

    @Test func zeroCallCountOmitted() {
        let h = Harness(UsageState(lastActiveAt: 0))
        h.client.start()
        h.client.flush()
        #expect(h.events[0].callCount == nil)
    }

    /// Billing counts distinct devices per calendar month, so a device in use
    /// must post a turnstile on every UTC day it is used. `suspend()` restamps
    /// the idle clock, so an app launched every 20 hours never sat idle for a
    /// full window and used to post only its first turnstile, then carry its
    /// calls forever: counted in its first month and in no month after.
    @Test func dailyUseEmitsATurnstileEveryUTCDay() {
        let h = Harness(UsageState())
        h.clock = 1_704_067_200_000 + 9 * hourMs   // 2024-01-01T09:00Z
        var usedDays = Set<Int64>()
        for _ in 0..<40 {
            usedDays.insert(utcDay(h.clock))
            h.relaunch()
            h.client.start()
            h.client.recordCall()
            h.client.flush()
            h.client.suspend()
            h.advance(20 * hourMs)
        }
        let sentDays = Set(h.sent.map { utcDay($0.at) })
        #expect(sentDays == usedDays)
        let sentCalls = h.events.reduce(0) { $0 + ($1.callCount ?? 0) }
        #expect(sentCalls + h.state.carryCallCount == 40)
    }

    /// A new UTC day opens a turnstile even inside the window, and the carried
    /// calls ride it.
    @Test func aNewUTCDayEmitsInsideTheWindow() {
        let midnight: Int64 = 1_706_745_600_000   // 2024-02-01T00:00Z
        let h = Harness(UsageState(lastActiveAt: midnight - 60_000, carryCallCount: 4, lastEmitDay: utcDay(midnight) - 1))
        h.clock = midnight + 60_000
        h.client.start()
        h.client.recordCall()
        h.client.flush()
        #expect(h.sent.count == 1)
        #expect(h.events[0].callCount == 5)
        #expect(h.state == UsageState(lastActiveAt: midnight + 60_000, carryCallCount: 0, lastEmitDay: utcDay(midnight)))

        // A relaunch later that day stays throttled, and carries.
        h.relaunch()
        h.advance(hourMs)
        h.client.start()
        h.client.recordCall(2)
        h.client.flush()
        #expect(h.sent.count == 1)
        #expect(h.state.carryCallCount == 2)
    }

    /// State written before the emit day was stored has none: the first start
    /// after the upgrade emits, whatever the window says, and takes the carry.
    @Test func stateWithoutAnEmitDayEmitsOnTheFirstStart() {
        let now: Int64 = 1_000_000_000_000
        let h = Harness(UsageState(lastActiveAt: now - 1000, carryCallCount: 3))
        h.client.start()
        h.client.flush()
        #expect(h.sent.count == 1)
        #expect(h.events[0].callCount == 3)
        #expect(h.state.lastEmitDay == utcDay(now))
    }

    @Test func utcDayFloorsToTheDay() {
        #expect(utcDay(0) == 0)
        #expect(utcDay(dayMs - 1) == 0)
        #expect(utcDay(dayMs) == 1)
        #expect(utcDay(-1) == -1)
        #expect(utcDay(-dayMs) == -1)
        #expect(utcDay(1_706_745_600_000) == 19754)   // 2024-02-01
    }

    @Test func webSessionSuspendAndReturn() {
        let h = Harness(UsageState(lastActiveAt: 0), windowMs: webSessionMs)

        h.client.start() // session 1
        h.client.flush()
        #expect(h.sent.count == 1)

        h.client.suspend() // tab hidden — stamp idle clock

        // Return within the idle window: same session, no new emit.
        h.advance(webSessionMs - 1000)
        h.client.start()
        #expect(h.sent.count == 1)

        // Return past the idle window: new session, new turnstile.
        h.client.suspend()
        h.advance(webSessionMs + 1000)
        h.client.start()
        h.client.flush()
        #expect(h.sent.count == 2)
        #expect(h.events[1].name == "load")
    }
}

struct WireTests {
    @Test func buildBodySerializesExpectedJSON() throws {
        // Capture the device id once: on platforms without persistent storage
        // (e.g. WASI in-memory) each defaultStorage() call yields a fresh UUID.
        let deviceId = defaultStorage().persistentDeviceId()
        let body = IngestBody(
            platform: "test",
            app: AppInfo(id: "co.acme.app"),
            sdk: SDKInfo(name: "desert-ant-core", version: "0.1.0"),
            sentAt: "2024-01-02T03:04:05.678Z",
            events: [IngestEvent(deviceId: deviceId, callCount: 3, context: ["appVersion": "1.0"])]
        )
        let json = try buildBody(body)
        // Object keys are sorted (deterministic, identical across platforms).
        #expect(json == #"{"app":{"id":"co.acme.app"},"events":[{"callCount":3,"context":{"appVersion":"1.0"},"deviceId":"\#(deviceId)","name":"load"}],"platform":"test","sdk":{"name":"desert-ant-core","version":"0.1.0"},"sentAt":"2024-01-02T03:04:05.678Z"}"#)
    }

    @Test func attributionAndOptionalFieldsOmittedWhenUnset() throws {
        let body = IngestBody(platform: "test", sentAt: "2024-01-02T03:04:05.678Z", events: [IngestEvent(deviceId: defaultStorage().persistentDeviceId())])
        let json = try buildBody(body)
        #expect(!json.contains("\"key\""))
        #expect(!json.contains("\"app\""))
        #expect(!json.contains("callCount"))
        #expect(!json.contains("context"))
    }

    @Test func specialCharsAreEscaped() throws {
        let body = IngestBody(platform: "test", sentAt: "t", events: [IngestEvent(deviceId: #"a"b\c"#)])
        let json = try buildBody(body)
        #expect(json.contains(#""deviceId":"a\"b\\c""#))
    }

    @Test func platformDefaultsToBuildTarget() throws {
        // No platform passed: IngestBody fills it from the build target.
        let body = IngestBody(sentAt: "t", events: [IngestEvent(deviceId: "d")])
        // The ingest API accepts exactly these values; build targets map onto them.
        #if os(macOS) || os(Linux)
        #expect(body.platform == "server")
        #elseif os(iOS) || os(tvOS) || os(visionOS) || os(watchOS)
        #expect(body.platform == "ios")
        #elseif os(Android)
        #expect(body.platform == "android")
        #elseif os(WASI)
        // One wasm binary serves two hosts, detected at runtime: a browser is
        // "web", Node (where this suite runs on CI) is "server".
        #expect(body.platform == "web" || body.platform == "server")
        #endif
        #expect(["ios", "android", "web", "server"].contains(body.platform))
        #expect(body.platform == defaultPlatform)
    }

    @Test func iso8601FormatsUTC() {
        // 2024-01-02T03:04:05.678Z == 1704164645678 ms
        #expect(iso8601(epochMs: 1_704_164_645_678) == "2024-01-02T03:04:05.678Z")
    }

    @Test func generateUUIDHasV4Shape() {
        let id = generateUUID()
        #expect(id.count == 36)
        let parts = id.split(separator: "-")
        #expect(parts.count == 5)
        #expect(parts[2].first == "4") // version nibble
    }
}
