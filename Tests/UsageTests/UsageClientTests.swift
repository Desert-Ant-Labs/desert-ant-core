import Testing
@testable import Usage

// A test harness: in-memory persisted state, a controllable clock, and a sink
// that captures every sent body.
private final class Harness {
    var state: UsageState
    var clock: Int64 = 1_000_000_000_000
    var sent: [(body: IngestBody, opts: SendOptions)] = []
    let client: UsageClient

    init(_ initial: UsageState = UsageState(), callCount: (() -> Int)? = nil, windowMs: Int64 = dayMs) {
        self.state = initial
        // Captured by reference through the closures below.
        var boxRef: Harness!
        self.client = UsageClient(ClientDeps(
            deviceId: "dev-1",
            key: "dal_test",
            platform: "test",
            callCount: callCount,
            windowMs: windowMs,
            now: { boxRef.clock },
            loadState: { boxRef.state },
            saveState: { boxRef.state = $0 },
            send: { body, opts in boxRef.sent.append((body, opts)) }
        ))
        boxRef = self
    }

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

    @Test func startDoesNotEmitWithinWindow() {
        let now: Int64 = 1_000_000_000_000
        let h = Harness(UsageState(lastActiveAt: now - (dayMs - 1)))
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
        let h = Harness(UsageState(lastActiveAt: now - 1000))
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

    @Test func manualLoadBypassesWindow() {
        let now: Int64 = 1_000_000_000_000
        let h = Harness(UsageState(lastActiveAt: now - 1000))
        h.client.load()
        #expect(h.sent.count == 1)
        #expect(h.events[0].name == "load")
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
        let body = IngestBody(
            platform: "test",
            app: AppInfo(id: "co.acme.app"),
            sdk: SDKInfo(name: "desert-ant-core", version: "0.1.0"),
            sentAt: "2024-01-02T03:04:05.678Z",
            events: [IngestEvent(deviceId: "dev-1", callCount: 3, context: ["appVersion": "1.0"])]
        )
        let json = try buildBody(body)
        // Object keys are sorted (deterministic, identical across platforms).
        #expect(json == #"{"app":{"id":"co.acme.app"},"events":[{"callCount":3,"context":{"appVersion":"1.0"},"deviceId":"dev-1","name":"load"}],"platform":"test","sdk":{"name":"desert-ant-core","version":"0.1.0"},"sentAt":"2024-01-02T03:04:05.678Z"}"#)
    }

    @Test func attributionAndOptionalFieldsOmittedWhenUnset() throws {
        let body = IngestBody(platform: "test", sentAt: "2024-01-02T03:04:05.678Z", events: [IngestEvent(deviceId: "dev-1")])
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
        #if os(macOS)
        #expect(body.platform == "macos")
        #elseif os(iOS)
        #expect(body.platform == "ios")
        #elseif os(Linux)
        #expect(body.platform == "linux")
        #elseif os(Android)
        #expect(body.platform == "android")
        #elseif os(WASI)
        #expect(body.platform == "web")
        #else
        #expect(!body.platform.isEmpty)
        #endif
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
