import Testing
@testable import Tongue
@testable import Usage

/// Where an in-memory client keeps its state and everything it sent.
/// `@unchecked Sendable` so the client, which closes over this, can be handed to
/// the turnstile's actor: the test only reads it after awaiting a flush.
private final class Sink: @unchecked Sendable {
    var state = UsageState(lastActiveAt: 0)
    var sent: [IngestBody] = []
}

struct TongueUsage {
    /// A flush pass must reach this turnstile, which has no `TrackedSession` to
    /// register for it. Without the hook the detection waits out the three
    /// second debounce, so nothing has been sent when the pass returns.
    @Test func aFlushPassForcesTheDebouncedDetectionOut() async {
        let sink = Sink()
        let client = UsageClient(ClientDeps(
            deviceId: "tongue-flush",
            platform: "test",
            now: { 1_000_000_000_000 },
            loadState: { sink.state },
            saveState: { sink.state = $0 },
            send: { body, _ in sink.sent.append(body) }
        ))
        let telemetry = TelemetryDebug(sends: InflightSends())
        let turnstile = UsageTurnstile(client: client, telemetry: telemetry)
        await turnstile.record()
        #expect(sink.sent.isEmpty, "the debounce sent before its delay")

        await telemetry.flushAndWait()
        #expect(sink.sent.count == 1, "the flush pass did not reach the turnstile")
        #expect(sink.sent.first?.events.first?.callCount == 1)
    }

    /// `detect` is synchronous, so it records from a task of its own, and a
    /// flush started right after it used to run before that task: almost every
    /// pass returned having sent nothing. Many fresh turnstiles, because a
    /// single one can win the race by luck.
    @Test func aFlushRightAfterABackgroundRecordStillSendsIt() async {
        var missed = 0
        for index in 0..<100 {
            let sink = Sink()
            let client = UsageClient(ClientDeps(
                deviceId: "tongue-race-\(index)",
                platform: "test",
                now: { 1_000_000_000_000 },
                loadState: { sink.state },
                saveState: { sink.state = $0 },
                send: { body, _ in sink.sent.append(body) }
            ))
            let telemetry = TelemetryDebug(sends: InflightSends())
            let turnstile = UsageTurnstile(client: client, telemetry: telemetry)
            turnstile.recordInBackground()
            await telemetry.flushAndWait()
            if sink.sent.first?.events.first?.callCount != 1 { missed += 1 }
        }
        #expect(missed == 0, "\(missed) of 100 flushes ran before the recorded call")
    }
}
