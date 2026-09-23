// Replays the ports' shared turnstile contract through core's own client. The
// Kotlin and JavaScript ports replay the identical file against their hand-ported
// clients, so this is what holds them to the behaviour here rather than to a copy
// of it. Only on macOS and Linux: the file is read off the checkout, which a
// simulator, wasm or on-device run cannot reach.

#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import Usage

private struct Vectors: Decodable {
    struct Case: Decodable {
        var name: String
        var stateLastActiveAt: Int64
        var stateCarry: Int
        var stateEmitDay: Int64
        var stepKinds: [String]
        var stepAt: [Int64]
        var stepN: [Int]
        var sendCounts: [Int]
        var finalLastActiveAt: Int64
        var finalCarry: Int
        var finalEmitDay: Int64
    }
    var windowMs: Int64
    var cases: [Case]
}

struct UsageVectorTests {
    @Test func turnstileMatchesTheSharedContract() throws {
        // #filePath is Tests/UsageTests/<file>, so the repo root is three up.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("packages/tongue-node/test/usage_vectors.json"))
        let vectors = try JSONDecoder().decode(Vectors.self, from: data)
        #expect(!vectors.cases.isEmpty)

        for c in vectors.cases {
            var state = UsageState(
                lastActiveAt: c.stateLastActiveAt,
                carryCallCount: c.stateCarry,
                lastEmitDay: c.stateEmitDay < 0 ? nil : c.stateEmitDay
            )
            var now: Int64 = 0
            var sends: [IngestBody] = []
            let makeClient = {
                UsageClient(ClientDeps(
                    deviceId: "device-under-test",
                    platform: "test",
                    context: { nil },
                    windowMs: vectors.windowMs,
                    now: { now },
                    loadState: { state },
                    saveState: { state = $0 },
                    send: { body, _ in sends.append(body) }
                ))
            }
            var client = makeClient()

            for (i, kind) in c.stepKinds.enumerated() {
                now = c.stepAt[i]
                switch kind {
                case "start": client.start()
                case "flush": client.flush()
                case "record": client.recordCall(c.stepN[i])
                case "suspend": client.suspend()
                case "relaunch": client = makeClient()
                default: Issue.record("\(c.name): unknown step \(kind)")
                }
            }

            #expect(sends.map { $0.events[0].callCount ?? -1 } == c.sendCounts, "\(c.name): sends")
            #expect(sends.allSatisfy { $0.events[0].name == "load" && $0.events[0].deviceId == "device-under-test" }, "\(c.name)")
            #expect(state.lastActiveAt == c.finalLastActiveAt, "\(c.name): final lastActiveAt")
            #expect(state.carryCallCount == c.finalCarry, "\(c.name): final carry")
            #expect((state.lastEmitDay ?? -1) == c.finalEmitDay, "\(c.name): final emit day")
        }
    }
}
#endif
