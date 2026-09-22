import Testing
@testable import Usage
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Flipped once, read synchronously from a hook's `isAlive`. No lock: it is set
/// before the `flushAndWait` that reads it, and the actor hop orders the two.
private final class Doomed: @unchecked Sendable {
    private(set) var isSet = false
    func set() { isSet = true }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}

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

    /// The same handshake through the real transport, which is where the old
    /// code registered from a separate task. It counts registrations rather than
    /// live sends, so a send that has already failed and left the registry still
    /// counts: a threaded host with no silent listener (Windows, Android) points
    /// at a closed port, where the send fails at once. Where the listener exists
    /// it holds the requests open, so none fail while the test runs.
    @Test func makeSendRegistersItsSendBeforeReturning() async {
        let registry = InflightSends()
        let sends = 32
        #if canImport(Darwin) || canImport(Glibc)
        guard let (fd, port) = silentListener() else {
            Issue.record("could not open a local listener")
            return
        }
        let endpoint = "http://127.0.0.1:\(port)/ingest"
        #else
        let endpoint = "http://127.0.0.1:1/ingest"
        #endif
        let send = makeSend(endpoint: endpoint, registry: registry)
        // Repeated because a registration from another task can still win the
        // race now and then; across this many sends, one of them loses it.
        for sent in 1...sends {
            send(IngestBody(sentAt: "t", events: [IngestEvent(deviceId: "d")]), SendOptions())
            #expect(registry.registeredTotal == sent, "makeSend returned before its send was registered")
        }

        let pending = registry.drain()
        #if canImport(Darwin) || canImport(Glibc)
        // Closing the listener resets the queued connection, so the send fails
        // now rather than at the client's timeout.
        close(fd)
        for task in pending { await task.value }
        #endif
    }

    /// A registration that prunes while a pass runs used to shrink the list under
    /// the pass, whose merge (`live + dropFirst(marked)`) then dropped the hook
    /// that had just registered: that session's usage was never forced out again.

    /// A pass over many hooks must not nest a stack frame per hook. wasm has no
    /// guaranteed tail calls, so a sequential `await` per hook on its
    /// single-threaded executor grew the stack until it overflowed (the JS stack,
    /// or the shadow stack into the heap) at a few hundred hooks. The registration
    /// loop yields for the same reason, so only the pass is under test.
    @Test func aPassOverAThousandHooksCompletes() async {
        let telemetry = TelemetryDebug(sends: InflightSends())
        let flushed = Counter()
        for _ in 0..<1000 {
            await Task.yield()
            await telemetry.registerFlushHook(FlushHook(isAlive: { true }, flush: { await flushed.increment(); return true }))
        }
        await telemetry.flushAndWait()
        #expect(await flushed.value == 1000)
    }

    @Test func aHookRegisteredDuringAPassSurvivesThePrune() async {
        let telemetry = TelemetryDebug(sends: InflightSends())
        let lateFlushed = Flag()
        let late = FlushHook(isAlive: { true }, flush: { await lateFlushed.set(); return true })
        // Past the prune threshold, all live while they register (so none is
        // pruned yet), a third of them dead by the time the pass runs.
        let doomed = Doomed()
        for index in 0..<300 {
            await Task.yield() // see aPassOverAThousandHooksCompletes
            let dies = index % 3 == 0
            await telemetry.registerFlushHook(FlushHook(
                isAlive: { !(dies && doomed.isSet) },
                flush: { !(dies && doomed.isSet) }
            ))
        }
        let registered = Flag()
        await telemetry.registerFlushHook(FlushHook(isAlive: { true }, flush: {
            if await !registered.isSet {
                await registered.set()
                await telemetry.registerFlushHook(late)
            }
            return true
        }))
        doomed.set()
        await telemetry.flushAndWait()
        #expect(await !lateFlushed.isSet, "a hook registered mid-pass ran in that pass")
        await telemetry.flushAndWait()
        #expect(await lateFlushed.isSet, "the hook registered during the first pass was dropped")
    }

    @Test func aKeyIsTrimmedAndABlankOneIsNone() {
        #expect(trimmedKey("dal_live_x\n") == "dal_live_x")
        #expect(trimmedKey("  dal_live_x \r\n") == "dal_live_x")
        #expect(trimmedKey(" \n") == nil)
        #expect(trimmedKey(nil) == nil)
    }

    #if canImport(Darwin) || canImport(Glibc)
    /// A usage POST to an endpoint that accepts and never answers gives up after
    /// the send timeout, not URLSession's 60 s default: `flushTelemetry()` awaits
    /// it, and a worker's exit waits on that.
    @Test func aSendToASilentEndpointGivesUpAtTheSendTimeout() async {
        guard let (fd, port) = silentListener() else {
            Issue.record("could not open a listener")
            return
        }
        defer { close(fd) }
        let registry = InflightSends()
        let send = makeSend(endpoint: "http://127.0.0.1:\(port)/ingest", registry: registry)
        let clock = ContinuousClock()
        let started = clock.now
        send(IngestBody(sentAt: "t", events: [IngestEvent(deviceId: "d")]), SendOptions())
        for task in registry.drain() { await task.value }
        #expect(clock.now - started < .seconds(20), "the send waited out the platform default timeout")
    }
    #endif
}

#if canImport(Darwin) || canImport(Glibc)
/// A 127.0.0.1 listener on a free port that never accepts: a client connects
/// through the kernel backlog and then waits for a reply that never comes.
private func silentListener() -> (Int32, UInt16)? {
    #if canImport(Glibc)
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    guard fd >= 0 else { return nil }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, len) == 0 && listen(fd, 64) == 0 && getsockname(fd, $0, &len) == 0
        }
    }
    guard ok else { close(fd); return nil }
    return (fd, UInt16(bigEndian: addr.sin_port))
}
#endif
