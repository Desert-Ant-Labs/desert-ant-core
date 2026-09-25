import Testing
import Usage
@testable import Inference

// Sequential, awaited runs + explicit flush, so no locking is needed (and it
// stays Foundation-free for the wasm test build).

private final class CountingSession: InferenceSession, @unchecked Sendable {
    private(set) var runs = 0
    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor] {
        runs += 1
        return []
    }
}

/// Captures every event any client would send.
private final class Sink: @unchecked Sendable {
    private(set) var events: [IngestEvent] = []
    func add(_ e: [IngestEvent]) { events.append(contentsOf: e) }
}

/// One turnstile per device, as the platform storage keeps it. Two sessions in a
/// process share this, which is what makes a group collapse across them.
private final class UsageStore: @unchecked Sendable {
    var byDevice: [String: UsageState] = [:]
    var saves = 0
}

/// A client wired to `sink`, reading and writing `store`.
private func testClientFactory(_ sink: Sink, _ store: UsageStore = UsageStore()) -> (String) -> UsageClient {
    { deviceId in
        UsageClient(ClientDeps(
            deviceId: deviceId,
            key: "test",
            platform: "test",
            now: { 1_000_000_000_000 },
            loadState: { store.byDevice[deviceId] ?? UsageState() },
            saveState: { store.byDevice[deviceId] = $0; store.saves += 1 },
            send: { body, _ in sink.add(body.events) }
        ))
    }
}

struct TrackedSessionTests {
    @Test func recordsACallPerRunAndSendsOnFlush() async throws {
        let sink = Sink()
        let counting = CountingSession()
        let tracked = TrackedSession(wrapping: counting, flushAfter: 60, clientFactory: testClientFactory(sink))

        _ = try await tracked.run(inputs: [:], outputs: [], deviceId: "d")
        _ = try await tracked.run(inputs: [:], outputs: [], deviceId: "d")
        await tracked.flush()

        #expect(counting.runs == 2)
        let calls = sink.events.filter { $0.name == "load" }.compactMap { $0.callCount }.reduce(0, +)
        #expect(calls == 2)   // both runs recorded (turnstile + delta, server sums)
    }

    @Test func attributesRunsToPerCallDevice() async throws {
        let sink = Sink()
        let tracked = TrackedSession(wrapping: CountingSession(), flushAfter: 60, clientFactory: testClientFactory(sink))

        _ = try await tracked.run(inputs: [:], outputs: [], deviceId: "user-A")
        _ = try await tracked.run(inputs: [:], outputs: [], deviceId: "user-B")
        _ = try await tracked.run(inputs: [:], outputs: [], deviceId: "user-A")
        await tracked.flush()

        // Multi-tenant: distinct devices each get their own turnstile load.
        let devices = Set(sink.events.filter { $0.name == "load" }.map { $0.deviceId })
        #expect(devices == ["user-A", "user-B"])
    }

    /// The documented contract is one call per device inside a group, so a second run on the
    /// same session must not count again.
    @Test func aCallGroupCollapsesRunsOnOneSession() async throws {
        let sink = Sink()
        let tracked = TrackedSession(wrapping: CountingSession(), flushAfter: 60, clientFactory: testClientFactory(sink))

        try await InferenceContext.withCallGroup {
            _ = try await tracked.run(inputs: [:], outputs: [], deviceId: "ch-1")
            _ = try await tracked.run(inputs: [:], outputs: [], deviceId: "ch-1")
        }
        await tracked.flush()

        let calls = sink.events.filter { $0.name == "load" }.compactMap { $0.callCount }.reduce(0, +)
        #expect(calls == 1)
    }

    /// The align cascade runs one operation over two sessions (coarse and fine), and each
    /// session has its own client for the same device. Grouping per device must still bill
    /// once; grouping per client would bill twice.
    @Test func aCallGroupCollapsesRunsAcrossSessions() async throws {
        let sink = Sink()
        // A factory each, as production has: the session factory builds one per session.
        // One store, as production has: the platform storage is per process, not per session.
        let store = UsageStore()
        let coarse = TrackedSession(wrapping: CountingSession(), flushAfter: 60, clientFactory: testClientFactory(sink, store))
        let fine = TrackedSession(wrapping: CountingSession(), flushAfter: 60, clientFactory: testClientFactory(sink, store))

        try await InferenceContext.withCallGroup {
            _ = try await coarse.run(inputs: [:], outputs: [], deviceId: "ch-1")
            _ = try await fine.run(inputs: [:], outputs: [], deviceId: "ch-1")
        }
        await coarse.flush()
        await fine.flush()

        let loads = sink.events.filter { $0.name == "load" }
        #expect(loads.compactMap { $0.callCount }.reduce(0, +) == 1, "one operation bills one call, however many sessions it runs")
        #expect(loads.count == 1, "and only the session that counted posts, as the shared turnstile does in production")
        // The shape the shared storage hides: the second call is carried, not posted.
        #expect(store.byDevice["ch-1"]?.carryCallCount ?? 0 == 0, "and nothing is left carried for the next load to add")
    }

    /// The flush emits one load per device, not one per session: the align
    /// cascade is two sessions over one device, and forcing each of them would post that
    /// device's usage twice. It reports the calls made, never an invented one, and the
    /// session that loses the claim carries its call rather than losing it.
    @Test func aTelemetryFlushForcesOneLoadPerDevice() async throws {
        let sink = Sink()
        let store = UsageStore()
        let coarse = TrackedSession(wrapping: CountingSession(), flushAfter: 60, clientFactory: testClientFactory(sink, store))
        let fine = TrackedSession(wrapping: CountingSession(), flushAfter: 60, clientFactory: testClientFactory(sink, store))

        _ = try await coarse.run(inputs: [:], outputs: [], deviceId: "cascade")
        _ = try await fine.run(inputs: [:], outputs: [], deviceId: "cascade")
        await TelemetryDebug.shared.flushAndWait()

        let loads = sink.events.filter { $0.name == "load" }
        #expect(loads.count == 1, "a forced flush emits one load per device, however many sessions ran")
        #expect(loads.compactMap { $0.callCount }.reduce(0, +) == 1, "and it reports the call that was made, not an invented one")
        #expect(loads.first?.deviceId == "cascade", "and it reports the device the session served")

        await TelemetryDebug.shared.flushAndWait()
        let after = sink.events.filter { $0.name == "load" }
        #expect(after.count == 2, "the other session's call is carried, so the next pass reports it rather than dropping it")
        #expect(after.compactMap { $0.callCount }.reduce(0, +) == 2, "and two passes report each recorded call exactly once")
    }

    /// Per device, so a group spanning two end users still counts each of them.
    @Test func aCallGroupCountsEachDeviceOnce() async throws {
        let sink = Sink()
        let tracked = TrackedSession(wrapping: CountingSession(), flushAfter: 60, clientFactory: testClientFactory(sink))

        try await InferenceContext.withCallGroup {
            _ = try await tracked.run(inputs: [:], outputs: [], deviceId: "user-A")
            _ = try await tracked.run(inputs: [:], outputs: [], deviceId: "user-B")
            _ = try await tracked.run(inputs: [:], outputs: [], deviceId: "user-A")
        }
        await tracked.flush()

        let calls = sink.events.filter { $0.name == "load" }.compactMap { $0.callCount }.reduce(0, +)
        #expect(calls == 2, "one call per distinct device, not one per group")
    }

    @Test func nothingIsSentIfInferenceNeverRan() async throws {
        let sink = Sink()
        let tracked = TrackedSession(wrapping: CountingSession(), flushAfter: 60, clientFactory: testClientFactory(sink))
        await tracked.suspend()
        await tracked.flush()
        #expect(sink.events.isEmpty)
    }

    /// The switch is a consent flag a web page flips after load: while it is on a
    /// run records nothing and opens no client (so no store write and no device
    /// id), the run after it is cleared reports, and a call recorded before it
    /// is set again is held, neither stored nor sent, until it is cleared.
    @Test func theOptOutIsReadPerRun() async throws {
        final class Switch: @unchecked Sendable { var on = true; var opened = 0 }
        let off = Switch()
        let sink = Sink()
        let counting = CountingSession()
        let store = UsageStore()
        let factory = testClientFactory(sink, store)
        let tracked = TrackedSession(
            wrapping: counting, flushAfter: 60,
            clientFactory: { off.opened += 1; return factory($0) },
            disabled: { off.on }
        )

        _ = try await tracked.run(inputs: [:], outputs: [], deviceId: "d")
        await tracked.flush()
        #expect(counting.runs == 1, "a switched-off run must still run")
        #expect(off.opened == 0, "a switched-off run opened a client")
        #expect(sink.events.isEmpty)

        off.on = false
        _ = try await tracked.run(inputs: [:], outputs: [], deviceId: "d")
        await tracked.flush()
        #expect(sink.events.compactMap(\.callCount).reduce(0, +) == 1, "the run after consent did not report")

        off.on = true
        _ = try await tracked.run(inputs: [:], outputs: [], deviceId: "d")
        await tracked.flush()
        #expect(counting.runs == 3)
        #expect(sink.events.compactMap(\.callCount).reduce(0, +) == 1, "a run after the opt-out was recorded")

        off.on = false
        _ = try await tracked.run(inputs: [:], outputs: [], deviceId: "d")
        off.on = true
        let saves = store.saves
        await tracked.flush()
        await tracked.suspend()
        await tracked.forceFlush()
        #expect(sink.events.compactMap(\.callCount).reduce(0, +) == 1, "a call recorded before the opt-out was sent after it")
        #expect(store.saves == saves, "a flush after the opt-out wrote the store")

        off.on = false
        await tracked.flush()
        #expect(sink.events.compactMap(\.callCount).reduce(0, +) == 2, "the held call was lost when consent returned")
    }

    @Test func forwardsRunErrors() async throws {
        struct Boom: Error {}
        final class Failing: InferenceSession, @unchecked Sendable {
            func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor] { throw Boom() }
        }
        let tracked = TrackedSession(wrapping: Failing(), flushAfter: 60, clientFactory: testClientFactory(Sink()))
        await #expect(throws: Boom.self) {
            _ = try await tracked.run(inputs: [:], outputs: [], deviceId: "d")
        }
    }
}
