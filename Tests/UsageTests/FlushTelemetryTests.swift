import Testing
@testable import Usage
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
