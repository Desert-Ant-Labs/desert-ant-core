// End-to-end behaviour on real audio, and the paths the golden clips are too
// short to reach: the fixtures are 2.3 s, one model window is 20.5 s, so nothing
// in the goldens crosses a chunk boundary.

import Foundation
import Testing

@testable import Cue

#if canImport(CoreML)

let MODEL_HINT: Comment = "needs the model: set CUE_MODEL_DIR or run Cue.download()"

@Suite(.enabled(if: Fixtures.hasModel, MODEL_HINT))
struct WindowPlanTests {
    static func pipeline() async throws -> Pipeline {
        let directory = try await Fixtures.resolvedModelDirectory()
        return Pipeline(assets: try Assets(directory: directory,
                                           computeUnits: .cpuAndNeuralEngine))
    }

    @Test func coversEveryFrameExactlyOnce() async throws {
        let p = try await Self.pipeline()
        for frames in [1, 100, 2047, 2048, 2049, 3000, 5000, 20000, 100_000] {
            let plan = p.windows(frames: frames)
            #expect(plan.first?.lo == 0, "\(frames): does not start at 0")
            #expect(plan.last?.hi == frames, "\(frames): does not end at \(frames)")
            for (a, b) in zip(plan, plan.dropFirst()) {
                #expect(a.hi == b.lo, "\(frames): gap or overlap at \(a.hi)")
            }
        }
    }

    @Test func everyWindowStaysInsideTheRealFrames() async throws {
        let p = try await Self.pipeline()
        let window = p.assets.configuration.windowFrames
        for frames in [2049, 3000, 5000, 20000] {
            for w in p.windows(frames: frames) {
                #expect(w.offset >= 0)
                // A window may only run past the end when the clip is shorter
                // than one window; past that it is anchored on real data, which
                // is what makes the chunking exact.
                #expect(w.offset + window <= frames, "\(frames): window ran past the end")
                #expect(w.lo >= w.offset, "\(frames): output starts before its window")
                #expect(w.hi <= w.offset + window, "\(frames): output ends after its window")
            }
        }
    }

    @Test func interiorWindowsCarryFullContext() async throws {
        let p = try await Self.pipeline()
        let c = p.assets.configuration
        let plan = p.windows(frames: 20000)
        #expect(plan.count > 1)
        for w in plan.dropFirst() {
            #expect(w.lo - w.offset >= c.lookbackFrames,
                    "an interior window must have \(c.lookbackFrames) frames of lookback")
        }
        for w in plan.dropLast() {
            #expect(w.offset + c.windowFrames - w.hi >= c.lookaheadFrames,
                    "an interior window must have \(c.lookaheadFrames) frames of lookahead")
        }
    }
}

/// The progress callback is `@Sendable`, so a test cannot just append to a
/// local.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Double] = []
    func record(_ v: Double) { lock.lock(); seen.append(v); lock.unlock() }
    func values() -> [Double] { lock.lock(); defer { lock.unlock() }; return seen }
}

@Suite(.enabled(if: Fixtures.hasModel, MODEL_HINT))
struct DetectionTests {
    /// Two fixture clips separated by 25 s of silence: longer than one model
    /// window, so the result can only be right if chunking is.
    static func longAudio() throws -> (samples: [Float], gaps: [ClosedRange<Double>]) {
        let a = try Fixtures.samples("hello_en.wav").map { $0 / 32768 }
        let b = try Fixtures.samples("hello_zh.wav").map { $0 / 32768 }
        let lead = [Float](repeating: 0, count: 16000 * 2)
        let middle = [Float](repeating: 0, count: 16000 * 25)
        let tail = [Float](repeating: 0, count: 16000 * 2)
        let samples = lead + a + middle + b + tail
        let aStart = Double(lead.count) / 16000
        let aEnd = aStart + Double(a.count) / 16000
        let bStart = aEnd + Double(middle.count) / 16000
        let bEnd = bStart + Double(b.count) / 16000
        return (samples, [aStart...aEnd, bStart...bEnd])
    }

    @Test func findsSpeechAcrossChunkBoundaries() async throws {
        let cue = try await Fixtures.cue()
        let (samples, gaps) = try Self.longAudio()
        let result = try cue.detect(samples: samples)
        #expect(result.duration > 30, "fixture must exceed one 20.5 s window")
        #expect(result.containsSpeech)
        // Both utterances found, and nothing invented in the 25 s of digital
        // silence between them.
        #expect(result.speech.count == 2, "expected two spans, got \(result.speech)")
        for (span, expected) in zip(result.speech, gaps) {
            #expect(expected.contains(span.start), "\(span) outside \(expected)")
            #expect(expected.contains(span.end), "\(span) outside \(expected)")
        }
    }

    @Test func chunkingAgreesWithASingleWindow() async throws {
        // The same audio short enough to fit one window, then padded past two:
        // the frames they share must come out the same, because a window given
        // full context is supposed to be exact rather than approximate.
        let cue = try await Fixtures.cue()
        let clip = try Fixtures.samples("hello_en.wav").map { $0 / 32768 }
        let short = try cue.detect(samples: clip)
        let padded = clip + [Float](repeating: 0, count: 16000 * 40)
        let long = try cue.detect(samples: padded)
        #expect(long.probabilities.count > short.probabilities.count)
        var worst: Float = 0
        for i in 0..<short.probabilities.count {
            worst = max(worst, abs(short.probabilities[i] - long.probabilities[i]))
        }
        // Not bit-identical: the short clip's tail is padded with the silence
        // frame while the long one has real (silent) audio there, which is a
        // real difference in the last lookahead frames.
        let head = short.probabilities.count - 200
        var worstHead: Float = 0
        for i in 0..<head {
            worstHead = max(worstHead, abs(short.probabilities[i] - long.probabilities[i]))
        }
        #expect(worstHead < 0.01, "chunking changed the interior by \(worstHead)")
    }

    @Test func digitalSilenceIsNotSpeech() async throws {
        let cue = try await Fixtures.cue()
        let result = try cue.detect(samples: [Float](repeating: 0, count: 16000 * 5))
        #expect(!result.containsSpeech, "found speech in silence: \(result.speech)")
        #expect(result.speechRatio == 0)
    }

    @Test func silenceIsTheComplementOfSpeech() async throws {
        let cue = try await Fixtures.cue()
        let (samples, _) = try Self.longAudio()
        let result = try cue.detect(samples: samples)
        let gaps = result.silence()
        #expect(!gaps.isEmpty)
        let total = result.speechDuration + gaps.reduce(0) { $0 + $1.duration }
        #expect(abs(total - result.duration) < 0.05, "spans do not tile the audio")
        for gap in gaps {
            for span in result.speech {
                #expect(gap.end <= span.start || gap.start >= span.end, "overlap")
            }
        }
    }

    @Test func paddingWidensAndCoalesces() async throws {
        let cue = try await Fixtures.cue()
        let clip = try Fixtures.samples("hello_en.wav").map { $0 / 32768 }
        let plain = try cue.detect(samples: clip)
        var options = Cue.Options()
        options.padding = 0.15
        let padded = try cue.detect(samples: clip, options: options)
        #expect(padded.speech.count <= plain.speech.count)
        #expect(padded.speechDuration > plain.speechDuration)
        // Never past the ends of the audio, and never overlapping.
        for span in padded.speech {
            #expect(span.start >= 0)
            #expect(span.end <= padded.duration)
        }
        for (a, b) in zip(padded.speech, padded.speech.dropFirst()) {
            #expect(a.end < b.start, "padding produced overlapping spans")
        }
    }

    @Test func biasMovesTheThresholdInTheRightDirection() async throws {
        let cue = try await Fixtures.cue()
        let clip = try Fixtures.samples("hello_en.wav").map { $0 / 32768 }
        func ratio(_ bias: Cue.Bias) throws -> Double {
            var o = Cue.Options(); o.bias = bias
            return try cue.detect(samples: clip, options: o).speechRatio
        }
        #expect(try ratio(.recall) >= ratio(.balanced))
        #expect(try ratio(.balanced) >= ratio(.precision))
    }

    @Test func tooShortToFrameIsAnError() async throws {
        let cue = try await Fixtures.cue()
        #expect(throws: CueError.self) {
            // Under one 25 ms window, so the frontend produces no frames.
            _ = try cue.detect(samples: [Float](repeating: 0, count: 200))
        }
        #expect(throws: CueError.self) {
            _ = try cue.detect(samples: [])
        }
    }

    /// The file entry point goes through AudioIO's decoder rather than the raw
    /// sample path the other tests use, so it is the one that would break if
    /// decoding handed back a different scale or channel count.
    @Test func readsAudioFiles() async throws {
        let cue = try await Fixtures.cue()
        let url = try #require(Bundle.module.url(forResource: "hello_en",
                                                 withExtension: "wav"))
        let seen = Recorder()
        let result = try await cue.detect(url) { seen.record($0) }
        #expect(result.containsSpeech)
        #expect(abs(result.duration - 2.24) < 0.05)
        // Same answer as feeding the samples in by hand.
        let direct = try cue.detect(samples: try Fixtures.samples("hello_en.wav")
            .map { $0 / 32768 })
        #expect(result.speech.count == direct.speech.count)
        for (a, b) in zip(result.speech, direct.speech) {
            #expect(abs(a.start - b.start) < 0.02)
            #expect(abs(a.end - b.end) < 0.02)
        }
        #expect(seen.values().last == 1.0, "progress must reach 1")
    }

    @Test func resamplesForeignRates() async throws {
        let cue = try await Fixtures.cue()
        let clip = try Fixtures.samples("hello_en.wav").map { $0 / 32768 }
        // Crude 2x upsample to 32 kHz; the API is supposed to bring it back.
        var upsampled = [Float](repeating: 0, count: clip.count * 2)
        for i in 0..<clip.count {
            upsampled[i * 2] = clip[i]
            upsampled[i * 2 + 1] = clip[i]
        }
        let result = try cue.detect(samples: upsampled, sampleRate: 32000)
        #expect(abs(result.duration - Double(clip.count) / 16000) < 0.01)
        #expect(result.containsSpeech)
    }
}

#endif
