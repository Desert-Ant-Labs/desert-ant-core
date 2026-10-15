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

@Suite(.serialized) struct FlushTelemetryTests {
    @Test func workIsRegisteredBeforeDispatchReturns() async {
        let registry = InflightWork()
        let gate = Gate()
        dispatchTracked(into: registry) { await gate.wait() }
        #expect(registry.count == 1, "the work was not registered when dispatch returned")
        await gate.release()
        await TelemetryDebug(work: registry).flushAndWait()
    }

    @Test func aFlushWaitsForTheWorkInFlight() async {
        let registry = InflightWork()
        let done = Flag()
        dispatchTracked(into: registry) {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await done.set()
        }
        await TelemetryDebug(work: registry).flushAndWait()
        #expect(await done.isSet, "flushAndWait returned before the work finished")
    }

    @Test func aFlushWaitsForWorkThatTheWorkStarted() async {
        let registry = InflightWork()
        let done = Flag()
        dispatchTracked(into: registry) {
            try? await Task.sleep(nanoseconds: 100_000_000)
            dispatchTracked(into: registry) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                await done.set()
            }
        }
        await TelemetryDebug(work: registry).flushAndWait()
        #expect(await done.isSet, "flushAndWait returned before the follow-up work finished")
    }

    @Test func twoFlushesAtOnceBothWait() async {
        let registry = InflightWork()
        let gate = Gate()
        dispatchTracked(into: registry) { await gate.wait() }
        let debug = TelemetryDebug(work: registry)
        let first = Flag()
        let second = Flag()
        let flushes = [
            Task { await debug.flushAndWait(); await first.set() },
            Task { await debug.flushAndWait(); await second.set() },
        ]
        try? await Task.sleep(nanoseconds: 200_000_000)
        let early = [await first.isSet, await second.isSet]
        #expect(early == [false, false], "a flush returned while the work was still running")
        await gate.release()
        for flush in flushes { await flush.value }
        let late = [await first.isSet, await second.isSet]
        #expect(late == [true, true])
    }

    @Test(.enabled(if: hostProvidedLicenseEndpoint() != nil))
    func aModelLoadIsRegisteredForTheNextFlush() async {
        let before = InflightWork.shared.registeredTotal
        licenseOnLoad(SDKInfo(name: "Test", version: "0.0.0", model: "flush-test", modelVersion: "v0"))
        #expect(InflightWork.shared.registeredTotal > before, "a model load started no tracked work")
        await TelemetryDebug.shared.flushAndWait()
    }

    @Test func aFlushDoesNotWaitForARetryStillInItsDelay() async {
        let fired = Flag()
        scheduleLicenseRetry(after: 60_000) { await fired.set() }
        await TelemetryDebug.shared.flushAndWait()
        #expect(await !fired.isSet)
    }

    @Test func aKeyIsTrimmedAndABlankOneIsNone() {
        #expect(trimmedKey("dal_live_x\n") == "dal_live_x")
        #expect(trimmedKey("  dal_live_x \r\n") == "dal_live_x")
        #expect(trimmedKey(" \n") == nil)
        #expect(trimmedKey(nil) == nil)
    }

    #if canImport(Darwin) || canImport(Glibc)
    @Test func aLicenseRequestToASilentEndpointGivesUpAtItsTimeout() async {
        guard let (fd, port) = silentListener() else {
            Issue.record("could not open a listener")
            return
        }
        defer { close(fd) }
        let client = LicenseClient(
            storage: SharedStorage(),
            schedule: { _, _ in },
            endpoint: { "http://127.0.0.1:\(port)/api/v1" },
            identity: { LicenseIdentity(appId: "com.acme.app", apiKey: nil, platform: "ios") })
        let clock = ContinuousClock()
        let started = clock.now
        await client.modelLoaded(model: "emo", modelVersion: "v0.7.0")
        // The client gives up at licenseTimeoutSeconds (10 s); the slack above it absorbs
        // suite parallelism on a loaded CI runner. The bound only needs to stay well under
        // Foundation's 60 s default to prove the timeout was passed at all.
        #expect(clock.now - started < .seconds(30), "flushTelemetry() would wait out the platform default timeout")
    }
    #endif
}

#if canImport(Darwin) || canImport(Glibc)
func silentListener() -> (Int32, UInt16)? {
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
