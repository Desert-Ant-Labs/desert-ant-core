import Testing
@testable import Usage

private actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}

/// A gate the test opens by hand, so a send stays in flight for as long as the
/// test needs it to.
private actor Gate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        open = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

struct FlushTelemetryTests {
    /// The handshake the flush rests on. The old transport registered its send
    /// from a separate task and the flush yielded a few times hoping that task
    /// had run, so the send was invisible for an unbounded moment after `send`
    /// returned. Checked synchronously, with the work held open, so nothing can
    /// have run in between: only a registration made before return passes.
    @Test func aSendIsRegisteredBeforeDispatchReturns() async {
        let registry = InflightSends()
        let gate = Gate()
        let done = Flag()
        dispatchTrackedSend(into: registry) {
            await gate.wait()
            await done.set()
        }
        #expect(registry.count == 1, "the send was not registered when dispatch returned")

        let pending = registry.drain()
        #expect(registry.count == 0)
        await gate.release()
        for task in pending { await task.value }
        #expect(await done.isSet, "awaiting the drained task did not await the send")
    }

    /// End to end through a flush pass: a hook starts a send that is still in
    /// flight well after the hook returns, and `flushAndWait` must not return
    /// before it lands. Its own instance and registry: a pass on the shared one
    /// forces every other suite's live sessions to emit mid-test.
    @Test func aFlushAwaitsTheSendItsHookStarted() async throws {
        let registry = InflightSends()
        let debug = TelemetryDebug(sends: registry)
        let done = Flag()
        let fired = Flag()
        await debug.registerFlushHook(
            FlushHook(
                isAlive: { true },
                flush: {
                    await fired.set()
                    dispatchTrackedSend(into: registry) {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        await done.set()
                    }
                    return false
                }
            )
        )
        await debug.flushAndWait()
        #expect(await fired.isSet)
        #expect(await done.isSet, "flushAndWait returned before the send it started finished")
    }
}
