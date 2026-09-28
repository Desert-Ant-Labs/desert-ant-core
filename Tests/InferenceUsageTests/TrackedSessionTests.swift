import Testing
#if !os(WASI)
import Dispatch
#endif
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

#if !os(WASI)
/// Holds the calling thread until `gate` is signaled, as synchronous inference holds a pool thread.
private func holdThread(_ gate: DispatchSemaphore) { gate.wait() }
#endif

// Serialized: aTelemetryFlushForcesOneLoadPerDevice force-flushes every live session through the shared telemetry.
@Suite(.serialized) struct TrackedSessionTests {
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

    /// Releasing one host handle suspends only the sessions its runs used; another handle's session sends nothing.
    @Test func suspendingAnOwnerTouchesOnlyItsOwnSessions() async throws {
        let sinkA = Sink()
        let sinkB = Sink()
        let a = TrackedSession(wrapping: CountingSession(), flushAfter: 60, clientFactory: testClientFactory(sinkA))
        let b = TrackedSession(wrapping: CountingSession(), flushAfter: 60, clientFactory: testClientFactory(sinkB))
        let ownerA = UInt.random(in: 1...UInt.max)
        let ownerB = ownerA &+ 1
        _ = try await InferenceContext.$owner.withValue(ownerA) { try await a.run(inputs: [:], outputs: [], deviceId: "a") }
        _ = try await InferenceContext.$owner.withValue(ownerB) { try await b.run(inputs: [:], outputs: [], deviceId: "b") }

        await SessionOwners.shared.suspendAll(owner: ownerA)
        #expect(sinkA.events.compactMap(\.callCount).reduce(0, +) == 1, "the released handle's call was not sent")
        #expect(sinkB.events.isEmpty, "another handle's session sent on release")
        await SessionOwners.shared.suspendAll(owner: ownerB)
    }

    /// A release inside the re-emit window carries the call instead of forcing a new load.
    @Test func suspendingInsideTheWindowCarriesRatherThanForcingALoad() async throws {
        let sink = Sink()
        let store = UsageStore()
        for cycle in 0..<2 {
            let owner = UInt.random(in: 1...UInt.max)
            let session = TrackedSession(wrapping: CountingSession(), flushAfter: 60, clientFactory: testClientFactory(sink, store))
            _ = try await InferenceContext.$owner.withValue(owner) { try await session.run(inputs: [:], outputs: [], deviceId: "d") }
            await SessionOwners.shared.suspendAll(owner: owner)
            #expect(sink.events.filter { $0.name == "load" }.count == 1, "cycle \(cycle) posted a load inside the window")
        }
        #expect(store.byDevice["d"]?.carryCallCount == 1, "the second cycle's call was not carried")
    }

    /// A release suspending a session while the exit drain suspends it too sends the pending usage exactly once.
    @Test func aReleaseRacingAnExitDrainSendsOnce() async throws {
        let sink = Sink()
        let session = TrackedSession(wrapping: CountingSession(), flushAfter: 60, clientFactory: testClientFactory(sink))
        let owner = UInt.random(in: 1...UInt.max)
        _ = try await InferenceContext.$owner.withValue(owner) { try await session.run(inputs: [:], outputs: [], deviceId: "race") }
        async let release: Void = SessionOwners.shared.suspendAll(owner: owner)
        async let drain: Void = session.suspend()
        _ = await (release, drain)
        #expect(sink.events.filter { $0.name == "load" }.count == 1, "the pending usage was sent twice or not at all")
        #expect(sink.events.compactMap(\.callCount).reduce(0, +) == 1)
    }

    #if !os(WASI)
    /// A release returns at once while every pool thread is blocked, and suspends the session before releasing it.
    @Test func aReleaseNeverBlocksOnABusyPool() async throws {
        let sink = Sink()
        let session = TrackedSession(wrapping: CountingSession(), flushAfter: 60, clientFactory: testClientFactory(sink))
        let owner = UInt.random(in: 1...UInt.max)
        _ = try await InferenceContext.$owner.withValue(owner) { try await session.run(inputs: [:], outputs: [], deviceId: "busy") }
        // Driven from a Dispatch thread, as a host's main thread calls it: the test's own task cannot resume while the pool is blocked.
        let elapsed: Duration = await withCheckedContinuation { continuation in
            DispatchQueue(label: "ai.desertant.tests.host").async {
                // More blocked tasks than any pool has threads, as synchronous inference holds them.
                let gate = DispatchSemaphore(value: 0)
                let blockers = 64
                for _ in 0..<blockers { Task.detached { holdThread(gate) } }
                // Freed on a timer of its own queue, so a release that blocks shows up as a slow call rather than a hang.
                DispatchQueue(label: "ai.desertant.tests.unblock").asyncAfter(deadline: .now() + .seconds(1)) {
                    for _ in 0..<blockers { gate.signal() }
                }
                _ = DispatchSemaphore(value: 0).wait(timeout: .now() + .milliseconds(100))
                let released = DispatchSemaphore(value: 0)
                let clock = ContinuousClock()
                let started = clock.now
                SessionOwners.shared.suspendAll(owner: owner) { released.signal() }
                let elapsed = clock.now - started
                released.wait()
                continuation.resume(returning: elapsed)
            }
        }
        #expect(elapsed < .milliseconds(50), "the release blocked the caller for \(elapsed)")
        #expect(sink.events.compactMap(\.callCount).reduce(0, +) == 1, "the session was released before it was suspended")
    }
    #endif

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
