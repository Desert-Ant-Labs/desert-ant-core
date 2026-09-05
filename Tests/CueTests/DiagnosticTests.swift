// Not assertions: these print the actual margins so a passing golden test can
// be trusted to be tight rather than tolerant. Kept because "it passed first
// try" is the moment to check the test can fail at all.

import Foundation
import Testing

@testable import Cue

#if canImport(CoreML)

@Suite(.enabled(if: Fixtures.hasModel, MODEL_HINT))
struct DiagnosticTests {
    @Test(.disabled("prints margins; enable when touching the frontend"))
    func reportMargins() async throws {
        let g = try Fixtures.golden()
        let frontend = try Fixtures.frontend()
        for clip in g.clips {
            let samples = try Fixtures.samples(clip.file)
            let (values, frames) = frontend.features(samples)
            var worstBin: Float = 0, worstSum: Float = 0
            for m in 0..<clip.mels {
                worstBin = max(worstBin, abs(values[m] - clip.firstFrame[m]))
                worstBin = max(worstBin,
                               abs(values[(frames - 1) * clip.mels + m] - clip.lastFrame[m]))
            }
            for f in 0..<frames {
                var s: Float = 0
                for m in 0..<clip.mels { s += values[f * clip.mels + m] }
                worstSum = max(worstSum, abs(s - clip.frameSums[f]))
            }
            print("\(clip.file): worst bin \(worstBin), worst frame sum \(worstSum)")
        }
        let cue = try await Fixtures.cue()
        for clip in g.clips {
            let samples = try Fixtures.samples(clip.file).map { $0 / 32768 }
            let r = try cue.detect(samples: samples)
            var worst: Float = 0
            for (a, b) in zip(r.probabilities, clip.probs) { worst = max(worst, abs(a - b)) }
            print("\(clip.file): worst prob delta \(worst), spans \(r.speech)")
        }
    }

    /// The WAV reader in `Fixtures` is hand-rolled, so it gets its own check:
    /// a sign error there would feed the frontend plausible-looking garbage and
    /// the golden comparison would fail somewhere far less obvious.
    @Test func fixtureReaderRecoversInt16() throws {
        let samples = try Fixtures.samples("hello_en.wav")
        #expect(samples.count > 16000)
        #expect(samples.contains { $0 < -1000 }, "no negative samples: sign error")
        #expect(samples.contains { $0 > 1000 }, "no loud samples")
        #expect(samples.allSatisfy { $0 >= -32768 && $0 <= 32767 }, "outside int16 range")
        // Real speech starts quiet; the fixture has a leading pause.
        let lead = samples.prefix(1600).map { abs($0) }.max() ?? 0
        let body = samples.dropFirst(8000).prefix(1600).map { abs($0) }.max() ?? 0
        #expect(lead < body, "expected a quiet lead-in relative to the middle")
    }

    /// A guard that the golden comparison is capable of failing: perturb the
    /// frontend's input and confirm the vectors no longer match.
    @Test func goldenComparisonDetectsDrift() throws {
        let g = try Fixtures.golden()
        let frontend = try Fixtures.frontend()
        let clip = g.clips[0]
        // Scaling by 2 shifts every log-mel bin by ln(4); if the test tolerance
        // could absorb that, it could absorb a real port bug.
        let samples = try Fixtures.samples(clip.file).map { $0 * 2 }
        let (values, _) = frontend.features(samples)
        var worst: Float = 0
        for m in 0..<clip.mels { worst = max(worst, abs(values[m] - clip.firstFrame[m])) }
        #expect(worst > FrontendGoldenTests.tolerance * 100,
                "a 4x energy change must be far outside tolerance, saw \(worst)")
    }
}

#endif
