#if canImport(CoreML)
import DesertAnt
import Foundation
import Testing

@testable import Usage
@testable import Voz

// The turnstile, tested without the model: it is the piece that would otherwise
// only be exercised by a 490 MB download, and the thing it guarantees - one
// recorded call per transcription, sent once per burst - is arithmetic.

/// Where an in-memory client keeps its clock, its state and everything it sent.
/// Separate from the client itself so the turnstile can be handed a freshly
/// made one - an actor takes ownership of a non-`Sendable` argument, so the
/// test cannot keep a second reference to it.
/// `@unchecked Sendable` so the client, which closes over this, can be handed to
/// the turnstile's actor: the test only reads it after awaiting a flush.
private final class Sink: @unchecked Sendable {
    var state = UsageState(lastActiveAt: 0)
    var clock: Int64 = 1_000_000_000_000
    var sent: [IngestBody] = []

    var calls: Int { sent.flatMap(\.events).compactMap(\.callCount).reduce(0, +) }
}

private func testClient(_ sink: Sink) -> UsageClient {
    UsageClient(ClientDeps(
        deviceId: "dev-1",
        key: "dal_test",
        sdk: VozModel.sdkInfo,
        platform: "test",
        now: { sink.clock },
        loadState: { sink.state },
        saveState: { sink.state = $0 },
        send: { body, _ in sink.sent.append(body) }
    ))
}

struct VozUsage {

    @Test func recordsOneCallPerTranscriptionAndSendsOncePerBurst() async throws {
        let sink = Sink()
        let turnstile = UsageTurnstile(client: testClient(sink))
        for _ in 0..<5 { await turnstile.record() }
        // The debounce coalesces the burst, so nothing has gone out yet.
        #expect(sink.sent.isEmpty)

        // Wait for the debounce rather than for a fixed interval: it is three
        // seconds, and a fixed four left a hundred milliseconds of margin - on
        // a loaded runner the actor's timer is scheduled late and the test
        // fails the machine rather than the code. What matters is that the
        // burst leaves as one send carrying five calls, however late it goes.
        let deadline = Date().addingTimeInterval(30)
        while sink.sent.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(sink.sent.count == 1)
        #expect(sink.calls == 5)
    }

    /// A flush pass must reach this turnstile, which has no `TrackedSession` to
    /// register for it. Without the hook the transcription waits out the three
    /// second debounce, so nothing has been sent when the pass returns.
    @Test func aFlushPassForcesTheDebouncedTranscriptionOut() async {
        let sink = Sink()
        let telemetry = TelemetryDebug(sends: InflightSends())
        let turnstile = UsageTurnstile(client: testClient(sink), telemetry: telemetry)
        await turnstile.record()
        #expect(sink.sent.isEmpty, "the debounce sent before its delay")

        await telemetry.flushAndWait()
        #expect(sink.sent.count == 1, "the flush pass did not reach the turnstile")
        #expect(sink.calls == 1)
    }

    @Test func reportsThisModelsIdentityRatherThanThePackages() {
        #expect(VozModel.sdkInfo.name == "Voz")
        #expect(VozModel.sdkInfo.version == VozModel.sdkVersion)
    }

    @Test func noTurnstileWhenUsageIsDisabled() {
        // The suite runs with DAL_USAGE_DISABLED set (networked CI must not post
        // a real event), which is exactly the case this asserts.
        if usageDisabled() {
            #expect(makeTurnstile() == nil)
        } else {
            #expect(makeTurnstile() != nil)
        }
    }
}
#endif
