import AudioIO
import Foundation
import Testing

@testable import Who

#if os(macOS)
/// How long the join takes on real speech and what memory it holds, printed, so a slow or heavy stage is caught here
/// and not in an app. `WHO_TIMING_REPEATS` repeats the eleven-minute excerpt that many times; 4 is 44 minutes.
@Suite(.serialized, .enabled(if: WhoFixtures.hasSchema2 && WhoFixtures.joinFixtures != nil && ProcessInfo.processInfo.environment["WHO_TIMING_REPEATS"] != nil,
                             "set WHO_MODEL_DIR, WHO_FIXTURES_DIR and WHO_TIMING_REPEATS"))
struct JoinTimingTests {
    @Test func timesTheJoinOnRepeatedSpeech() async throws {
        let directory = try #require(WhoFixtures.joinFixtures)
        let repeats = Int(ProcessInfo.processInfo.environment["WHO_TIMING_REPEATS"] ?? "1") ?? 1
        let idle = FootprintWatch.footprint()
        let who = try WhoFixtures.who()
        let rate = try await who.modelSampleRate()
        let excerpt = try await AudioIO.decode(path: directory + "/who_join_excerpt.wav", sampleRate: rate)
        var samples: [Float] = []
        samples.reserveCapacity(excerpt.count * repeats)
        for _ in 0..<repeats { samples += excerpt }
        _ = try await who.diarize(samples: Array(samples.prefix(Int(rate) * 20)), sampleRate: rate)          // the graphs compiled and warm
        let loaded = FootprintWatch.footprint()
        let watch = FootprintWatch()
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await who.diarize(samples: samples, sampleRate: rate)
        let seconds = Double((clock.now - start).components.seconds) + Double((clock.now - start).components.attoseconds) / 1e18
        let peak = watch.stop()
        print("JOIN TIMING: \(Int(result.duration / 60)) min of speech, \(result.speakerCount) speakers, \(String(format: "%.2f", seconds)) s, "
              + "\(String(format: "%.0f", result.duration / seconds))x realtime")
        print("JOIN MEMORY: idle \(FootprintWatch.text(idle)), model loaded and warm \(FootprintWatch.text(loaded)), "
              + "peak in the run \(FootprintWatch.text(peak)), the run's rise \(FootprintWatch.text(peak - watch.baseline))")
        #expect(seconds < result.duration / 20, "slower than 20x real time")
    }
}
#endif
