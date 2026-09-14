#if canImport(CoreML)
import AudioIO
import Foundation
import Testing

@testable import Voz

// Streaming coverage against a real model directory, opt-in the same way the
// offline suite is:
//
//   VOZ_MODEL_DIR=... VOZ_AUDIO=... swift test --filter VozLive
//
// The model must be a bundle with a realtime function (build_voz_live.py). An
// offline-only bundle makes the suite skip rather than fail, because that is a
// missing fixture and not a broken build.

private struct Fixture {
    let model: URL
    let audio: URL

    init?() {
        let env = ProcessInfo.processInfo.environment
        guard let model = env["VOZ_MODEL_DIR"], let audio = env["VOZ_AUDIO"] else {
            return nil
        }
        guard let meta = try? Data(contentsOf: URL(fileURLWithPath: model)
            .appendingPathComponent("meta.json")),
            let json = try? JSONSerialization.jsonObject(with: meta) as? [String: Any],
            json["realtime"] != nil
        else { return nil }
        self.model = URL(fileURLWithPath: model)
        self.audio = URL(fileURLWithPath: audio)
    }
}

// The suite itself carries no `@available`: swift-testing's macros refuse to
// expand on a declaration that has one. The floor is enforced per test with a
// runtime guard instead, which narrows the rest of the body just as well.
@Suite(.enabled(if: Fixture() != nil, "set VOZ_MODEL_DIR to a realtime bundle and VOZ_AUDIO"))
struct VozLiveTests {

    private func samples(_ fixture: Fixture, rate: Double) async throws -> [Float] {
        try await AudioIO.decode(path: fixture.audio.path, sampleRate: rate)
    }

    @Test func streamsTextWithBoundedLatency() async throws {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, *) else { return }
        let fixture = try #require(Fixture())
        let live = try Voz.Live(modelDirectory: fixture.model)
        await live.prewarm()

        let audio = try await samples(fixture, rate: live.sampleRate)
        let stream = await live.start()
        let collector = Task {
            var updates: [Voz.Live.Update] = []
            for await update in stream { updates.append(update) }
            return updates
        }

        // Paced at 1x, in 10 ms bites, the way a capture callback delivers.
        // Pacing is the point rather than an inconvenience: latency is measured
        // from the caller handing a sample over, so pushing a whole file at once
        // correctly reports tens of seconds for its tail. Only a short prefix is
        // used so the test costs its own duration and no more.
        let clip = Array(audio.prefix(Int(8 * live.sampleRate)))
        let bite = Int(0.01 * live.sampleRate)
        let began = Date()
        var index = 0
        while index < clip.count {
            let end = min(index + bite, clip.count)
            let due = Double(index) / live.sampleRate
            let ahead = due - Date().timeIntervalSince(began)
            if ahead > 0 { try await Task.sleep(nanoseconds: UInt64(ahead * 1e9)) }
            live.append(Array(clip[index..<end]))
            index = end
        }
        let result = try await live.finish()
        let updates = await collector.value

        #expect(result.duration > 0)
        // The loop ran, whether or not the weights had anything to say. Without
        // this the expectations below are vacuous on a model that emits nothing,
        // which is what a streaming export looks like before it is finetuned,
        // and the test would pass by saying nothing.
        #expect(result.processingTime > 0)
        #expect(!updates.isEmpty)
        // Each update is a snapshot of the whole transcript, so the last one has
        // to agree with what `finish` returns. A mismatch means the two compose
        // the two passes differently, which is the bug a caller would see as
        // text changing after they stopped speaking.
        #expect(updates.last?.text == result.text)
        // `stable` is a promise: it is a prefix of the transcript, and it only
        // ever grows. Breaking either turns a dictation client's minimal-edit
        // path into corruption.
        var previousStable = ""
        for update in updates {
            #expect(update.text.hasPrefix(update.stable))
            #expect(update.stable.hasPrefix(previousStable) || update.stable.isEmpty)
            if !update.stable.isEmpty { previousStable = update.stable }
        }

        // The contract, and it applies to the STREAMING pass only. Algorithmic
        // latency is fixed by the export and compute has to fit inside a chunk
        // or the stream falls behind without bound; one chunk of slack covers a
        // cold first dispatch. Refined updates are deliberately later than this
        // (a pass runs a second or so behind, by design), and the suite runs its
        // tests in parallel over one Neural Engine, so their latency here is not
        // a number worth bounding. The example measures that one at 1x.
        let algorithmic = await live.algorithmicLatency
        let bound = algorithmic + 2 * (await live.chunkDuration)
        for update in updates {
            #expect(update.latency >= 0)
            if update.source == .streaming {
                #expect(update.latency < bound)
            }
        }
        let worst = updates.map(\.latency).max() ?? 0
        print(String(format: "  voz.live: %d updates, %.1f s audio, compute %.2f s "
                             + "(duty %.0f%%), worst latency %.0f ms",
                     updates.count, result.duration, result.processingTime,
                     100 * result.processingTime / Swift.max(result.duration, 0.001),
                     worst * 1000))
    }

    @Test func wordsAreOrderedAndInsideTheAudio() async throws {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, *) else { return }
        let fixture = try #require(Fixture())
        let live = try Voz.Live(modelDirectory: fixture.model)
        let audio = try await samples(fixture, rate: live.sampleRate)
        _ = await live.start()
        live.append(audio)
        let result = try await live.finish()

        var previous = -1.0
        for word in result.words {
            #expect(word.start >= previous)
            #expect(word.end <= result.duration + 0.001)
            previous = word.start
        }
    }

    /// A second utterance on the same instance must not inherit the first's
    /// caches, its running normalizer or its prediction state. Reusing one
    /// instance across activations is the whole point of the API, so this is
    /// the failure mode that would matter most and show up least.
    /// The second pass has to actually run and actually change something, or
    /// the accuracy the product depends on is coming from nowhere.
    @Test func refinementCorrectsTheStreamingPass() async throws {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, *) else { return }
        let fixture = try #require(Fixture())
        let audio = try await samples(fixture, rate: 16000)

        var off = Voz.Live.Options()
        off.refine = false
        let streaming = try Voz.Live(modelDirectory: fixture.model, options: off)
        _ = await streaming.start()
        streaming.append(audio)
        let plain = try await streaming.finish()

        let hybrid = try Voz.Live(modelDirectory: fixture.model)
        let stream = await hybrid.start()
        let sources = Task { () -> Int in
            var refined = 0
            for await update in stream where update.source == .refined { refined += 1 }
            return refined
        }
        hybrid.append(audio)
        let refined = try await hybrid.finish()
        let refinedUpdates = await sources.value

        #expect(refinedUpdates > 0)
        // The whole point of the second pass: it sees more and says more.
        #expect(refined.words.count > plain.words.count)
        print(String(format: "  refine: %d words streaming-only, %d hybrid, %d passes",
                     plain.words.count, refined.words.count, refinedUpdates))
    }

    @Test func sessionsAreIndependent() async throws {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, *) else { return }
        let fixture = try #require(Fixture())
        let live = try Voz.Live(modelDirectory: fixture.model)
        let audio = try await samples(fixture, rate: live.sampleRate)

        _ = await live.start()
        live.append(audio)
        let first = try await live.finish()

        _ = await live.start()
        live.append(audio)
        let second = try await live.finish()

        #expect(first.text == second.text)
    }

    @Test func cancelLeavesTheInstanceUsable() async throws {
        guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, *) else { return }
        let fixture = try #require(Fixture())
        let live = try Voz.Live(modelDirectory: fixture.model)
        let audio = try await samples(fixture, rate: live.sampleRate)

        _ = await live.start()
        live.append(Array(audio.prefix(audio.count / 2)))
        await live.cancel()

        _ = await live.start()
        live.append(audio)
        let result = try await live.finish()
        #expect(!result.text.isEmpty)
    }
}
#endif
