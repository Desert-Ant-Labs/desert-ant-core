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

/// A client wired to `sink`, with its own in-memory turnstile state, for `deviceId`.
private func testClientFactory(_ sink: Sink) -> (String) -> UsageClient {
    { deviceId in
        final class Box: @unchecked Sendable { var state = UsageState() }
        let box = Box()
        return UsageClient(ClientDeps(
            deviceId: deviceId,
            key: "test",
            platform: "test",
            now: { 1_000_000_000_000 },
            loadState: { box.state },
            saveState: { box.state = $0 },
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
    /// once; grouping per client billed twice, which is what this pins.
    @Test func aCallGroupCollapsesRunsAcrossSessions() async throws {
        let sink = Sink()
        // A factory each, as production has: the session factory builds one per session.
        let coarse = TrackedSession(wrapping: CountingSession(), flushAfter: 60, clientFactory: testClientFactory(sink))
        let fine = TrackedSession(wrapping: CountingSession(), flushAfter: 60, clientFactory: testClientFactory(sink))

        try await InferenceContext.withCallGroup {
            _ = try await coarse.run(inputs: [:], outputs: [], deviceId: "ch-1")
            _ = try await fine.run(inputs: [:], outputs: [], deviceId: "ch-1")
        }
        await coarse.flush()
        await fine.flush()

        let calls = sink.events.filter { $0.name == "load" }.compactMap { $0.callCount }.reduce(0, +)
        #expect(calls == 1, "one operation bills one call, however many sessions it runs")
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
