import Testing
@testable import Usage
#if !os(WASI)
import Dispatch
#endif

private actor Counts {
    private(set) var drains = 0
    private(set) var flushes = 0
    func drained() { drains += 1 }
    func flushed() { flushes += 1 }
}

private final class Flag: @unchecked Sendable { var isSet = false }

#if !os(WASI)
/// Runs the blocking exit wait on a thread of its own, as a host's exit handler does, and returns how long it took.
private func timedExitWait(timeoutMs: Int, telemetry: TelemetryDebug, registry: InflightSends) async -> Duration {
    await withCheckedContinuation { continuation in
        DispatchQueue(label: "ai.desertant.tests.exit").async {
            let clock = ContinuousClock()
            let started = clock.now
            flushAndWaitForUsage(timeoutMs: timeoutMs, telemetry: telemetry, registry: registry)
            continuation.resume(returning: clock.now - started)
        }
    }
}
#endif

struct UsageDrainTests {
    /// A drain calls each live hook's drain, skips dead hooks and hooks without one, and never forces a flush.
    @Test func aDrainCallsLiveHooksDrainAndNeverTheirFlush() async {
        let telemetry = TelemetryDebug(sends: InflightSends())
        let counts = Counts()
        await telemetry.registerFlushHook(FlushHook(
            isAlive: { true },
            flush: { await counts.flushed(); return true },
            drain: { await counts.drained() }
        ))
        await telemetry.registerFlushHook(FlushHook(isAlive: { false }, flush: { true }, drain: { await counts.drained() }))
        await telemetry.registerFlushHook(FlushHook(isAlive: { true }, flush: { await counts.flushed(); return true }))
        await telemetry.drainLiveSessions()
        #expect(await counts.drains == 1)
        #expect(await counts.flushes == 0, "a drain forced a flush")
    }

    #if !os(WASI)
    /// The exit wait covers a send that a hook's drain starts, and returns once it has finished.
    @Test func theExitWaitCoversASendTheDrainStarts() async {
        let telemetry = TelemetryDebug(sends: InflightSends())
        let registry = InflightSends()
        let finished = Flag()
        await telemetry.registerFlushHook(FlushHook(isAlive: { true }, flush: { true }, drain: {
            dispatchTrackedSend(into: registry) {
                try? await Task.sleep(nanoseconds: 200_000_000)
                finished.isSet = true
            }
        }))
        // A bound past the ~90 s pool stall a cold Core ML compile can cause, so a busy pool delays the send without failing the test.
        let elapsed = await timedExitWait(timeoutMs: 150_000, telemetry: telemetry, registry: registry)
        #expect(finished.isSet, "the wait returned before the drained send finished")
        #expect(elapsed < .seconds(149), "the wait ran to its bound although the send had finished")
    }

    /// A send that a running flushAndWait is awaiting stays visible to the exit wait until it finishes.
    @Test func theExitWaitSeesASendAConcurrentFlushIsAwaiting() async throws {
        let registry = InflightSends()
        let flushing = TelemetryDebug(sends: registry)
        let finished = Flag()
        dispatchTrackedSend(into: registry) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            finished.isSet = true
        }
        let flush = Task { await flushing.flushAndWait() }
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = await timedExitWait(timeoutMs: 150_000, telemetry: TelemetryDebug(sends: InflightSends()), registry: registry)
        #expect(finished.isSet, "the exit wait returned while a flush held the send")
        await flush.value
    }

    /// The exit wait gives up at its bound however long a send takes.
    @Test func theExitWaitStopsAtItsBound() async {
        let registry = InflightSends()
        dispatchTrackedSend(into: registry) { try? await Task.sleep(nanoseconds: 3_000_000_000) }
        let elapsed = await timedExitWait(timeoutMs: 200, telemetry: TelemetryDebug(sends: InflightSends()), registry: registry)
        #expect(elapsed < .seconds(2), "the wait ran past its bound")
    }
    #endif
}
