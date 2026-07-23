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
