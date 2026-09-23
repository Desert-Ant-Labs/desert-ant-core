// Kept apart from TrackedSessionTests, which stays Foundation-free for the wasm
// test build: these need real threads, and wasm has one.
#if canImport(Foundation) && !os(WASI)
import Foundation
import Testing
import Usage
@testable import Inference

/// A session that does its work without suspending, the way a native backend
/// can: it holds its thread until the prediction is done. The ParallelRuns
/// tests use `Task.sleep`, which suspends, so they say nothing about a wrapper
/// in front of a session that does not.
///
/// A run blocks until a second run is active beside it, rather than sleeping a
/// fixed interval and hoping the scheduler overlapped another run inside it,
/// which made `peak` a race against a loaded CI runner. A wrapper that
/// serializes its runs can never have two active, so the first run waits out
/// the full deadline and `peak` stays 1; a wrapper that overlaps passes as
/// fast as two tasks can start.
private final class BlockingSession: InferenceSession, @unchecked Sendable {
    let runsConcurrently = true
    private let cond = NSCondition()
    private var active = 0
    private var _peak = 0
    private var _runs = 0

    var peak: Int { cond.lock(); defer { cond.unlock() }; return _peak }
    var runs: Int { cond.lock(); defer { cond.unlock() }; return _runs }

    /// Holds the thread without suspending - the whole point of this session.
    /// Synchronous because `NSCondition` is unavailable from async contexts.
    private func blockUntilOverlappedOrDeadline() {
        cond.lock()
        active += 1
        _peak = max(_peak, active)
        _runs += 1
        cond.broadcast()
        // `wait` blocks like a prediction does; the deadline only bounds the
        // failure case, where a serializing wrapper never overlaps a second run.
        let deadline = Date(timeIntervalSinceNow: 2)
        while _peak < 2, cond.wait(until: deadline) {}
        active -= 1
        cond.unlock()
    }

    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor] {
        blockUntilOverlappedOrDeadline()
        return []
    }
}

private final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [IngestEvent] = []
    var events: [IngestEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    func add(_ e: [IngestEvent]) { lock.lock(); defer { lock.unlock() }; _events.append(contentsOf: e) }
}

private func clientFactory(_ sink: Sink) -> (String) -> UsageClient {
    final class Store: @unchecked Sendable { var state: [String: UsageState] = [:] }
    let store = Store()
    return { deviceId in
        UsageClient(ClientDeps(
            deviceId: deviceId,
            key: "test",
            platform: "test",
            now: { 1_000_000_000_000 },
            loadState: { store.state[deviceId] ?? UsageState() },
            saveState: { store.state[deviceId] = $0 },
            send: { body, _ in sink.add(body.events) }
        ))
    }
}

struct TrackedSessionOverlapTests {
    /// The wrapper counts calls on an actor. The wrapped session's `run` is
    /// nonisolated, so it executes off that actor and the runs overlap - but
    /// nothing checked that, and a wrapper that queued every prediction would
    /// cost a two-engine part most of what ParallelRuns buys it (uhm's windows on
    /// an M3 Ultra: 121 ms each one at a time, 38 ms with four in flight).
    @Test func runsThroughTheWrapperStillOverlap() async throws {
        let inner = BlockingSession()
        let tracked = TrackedSession(wrapping: inner, flushAfter: 60, clientFactory: clientFactory(Sink()))

        try await ParallelRuns.run(count: 8, sessions: [tracked]) { _, session in
            _ = try await session.run(inputs: [:], outputs: [], deviceId: "d")
        }

        #expect(inner.runs == 8)
        #expect(inner.peak > 1, "runs behind the usage wrapper should overlap")
    }

    /// Overlapping the runs must not change what is billed: one call per run.
    @Test func overlappingRunsAreEachCountedOnce() async throws {
        let sink = Sink()
        let tracked = TrackedSession(wrapping: BlockingSession(), flushAfter: 60, clientFactory: clientFactory(sink))

        try await ParallelRuns.run(count: 8, sessions: [tracked]) { _, session in
            _ = try await session.run(inputs: [:], outputs: [], deviceId: "d")
        }
        await tracked.flush()

        let calls = sink.events.filter { $0.name == "load" }.compactMap { $0.callCount }.reduce(0, +)
        #expect(calls == 8)
    }
}
#endif
