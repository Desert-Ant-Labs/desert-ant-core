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

    /// The switch is a consent flag a page flips after load. While it is on a
    /// detection records nothing and opens no client, so no device id is minted;
    /// the one after it is cleared reports, and one after it is set again does not.
    @Test func theOptOutIsReadPerDetection() async {
        final class Switch: @unchecked Sendable { var on = true; var opened = 0 }
        let off = Switch()
        let sink = Sink()
        let telemetry = TelemetryDebug(sends: InflightSends())
        let turnstile = UsageTurnstile(
            client: {
                off.opened += 1
                return UsageClient(ClientDeps(
                    deviceId: "tongue-consent",
                    platform: "test",
                    now: { 1_000_000_000_000 },
                    loadState: { sink.state },
                    saveState: { sink.state = $0 },
                    send: { body, _ in sink.sent.append(body) }
                ))
            }(),
            telemetry: telemetry, disabled: { off.on }
        )
        turnstile.recordInBackground()
        await turnstile.record()
        await telemetry.flushAndWait()
        #expect(off.opened == 0, "a switched-off detection opened a client")
        #expect(sink.sent.isEmpty)

        off.on = false
        turnstile.recordInBackground()
        await telemetry.flushAndWait()
        #expect(sink.sent.compactMap { $0.events.first?.callCount }.reduce(0, +) == 1,
                "the detection after consent did not report")

        off.on = true
        turnstile.recordInBackground()
        await turnstile.record()
        await telemetry.flushAndWait()
        #expect(sink.sent.compactMap { $0.events.first?.callCount }.reduce(0, +) == 1,
                "a detection after the opt-out was recorded")
        #expect(off.opened == 1)
    }

    /// Tongue opens its own client rather than going through `Inference`, and it
    /// used to open it with no `sdk`, so every detection was reported as
    /// "desert-ant-core" at the package default version instead of as Tongue.
    @Test func reportsThisModelsIdentityRatherThanThePackages() {
        let sink = Sink()
        let client = makeTongueClient(
            storage: InMemoryStorage(),
            send: { body, _ in sink.sent.append(body) }
        )
        client.recordCall()
        client.load()
        #expect(sink.sent.count == 1)
        #expect(sink.sent.first?.sdk == TongueModel.sdkInfo)
        #expect(sink.sent.first?.sdk.name == "Tongue")
    }
}
