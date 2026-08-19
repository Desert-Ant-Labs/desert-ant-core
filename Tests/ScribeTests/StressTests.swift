#if canImport(CoreML)
import AudioIO
import Foundation
import Testing

@testable import Scribe

// A battery over real audio of varying length, rate and channel count, plus
// synthetic edge cases. Opt-in, because it needs the model and a corpus:
//
//   SCRIBE_MODEL_DIR=... SCRIBE_CORPUS=/path/to/audio swift test -c release \
//     --filter ScribeStress
//
// Each case asserts the invariants that should hold for *any* input, so a
// failure points at the implementation rather than at a WER target: word times
// must be ordered, land inside the audio, and agree with the transcript; the
// same input must produce the same output; and audio that carries speech must
// produce words.

private struct Corpus {
    let model: URL
    let files: [URL]

    init?() {
        let env = ProcessInfo.processInfo.environment
        guard let model = env["SCRIBE_MODEL_DIR"], let dir = env["SCRIBE_CORPUS"] else {
            return nil
        }
        self.model = URL(fileURLWithPath: model)
        let root = URL(fileURLWithPath: dir)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        files = names.sorted()
            .filter { ["wav", "flac", "mp3", "m4a"].contains(($0 as NSString).pathExtension) }
            .map { root.appendingPathComponent($0) }
    }
}

@Suite(.enabled(if: Corpus() != nil, "set SCRIBE_MODEL_DIR and SCRIBE_CORPUS"),
       .serialized)
struct ScribeStress {

    /// Invariants that must hold for every transcription, whatever the audio.
    private func check(_ result: Scribe.Result, label: String, duration: TimeInterval) {
        let starts = result.words.map(\.start)
        #expect(zip(starts, starts.dropFirst()).allSatisfy(<=), "\(label): word times must be non-decreasing")
        for start in starts {
            #expect(start >= 0 && start <= duration + 0.5, "\(label): word at \(start)s outside \(duration)s of audio")
        }
        // Words and text are two views of the same tokens; they must not diverge.
        let fromWords = result.words.map(\.text).joined(separator: " ")
        #expect(fromWords.split(separator: " ").count == result.words.count, "\(label): a word contains a space")
        if !result.words.isEmpty {
            #expect(!result.text.isEmpty, "\(label): words without text")
        }
        #expect(result.duration > 0, "\(label): duration not reported")
    }

    @Test func realWorldFiles() async throws {
        let corpus = try #require(Corpus())
        let scribe = try Scribe(modelDirectory: corpus.model)
        print("\n  \(pad("file", 22)) \(pad("audio", 9)) \(pad("proc", 8)) "
              + "\(pad("RTFx", 7)) \(pad("words", 7)) gap")
        for file in corpus.files {
            let samples = try await AudioIO.decode(path: file.path, sampleRate: 16000)
            let duration = Double(samples.count) / 16000
            let result = try await scribe.transcribe(file)
            check(result, label: file.lastPathComponent, duration: duration)

            // The largest silent stretch between consecutive words. A window that
            // decodes to nothing shows up here as a gap of 15 s or more.
            var gap = result.words.first?.start ?? 0
            for (a, b) in zip(result.words, result.words.dropFirst()) {
                gap = max(gap, b.start - a.start)
            }
            print("  \(pad(file.lastPathComponent, 22)) "
                  + "\(pad(String(format: "%.1fs", duration), 9)) "
                  + "\(pad(String(format: "%.2fs", result.processingTime), 8)) "
                  + "\(pad(String(format: "%.0f", result.realtimeFactor), 7)) "
                  + "\(pad(String(result.words.count), 7)) "
                  + String(format: "%.1fs", gap))
            #expect(gap < 15, "\(file.lastPathComponent): \(gap) s without a word suggests a window decoded to nothing")
        }
    }

    @Test func repeatedRunsAreIdentical() async throws {
        let corpus = try #require(Corpus())
        let file = try #require(corpus.files.first)
        let scribe = try Scribe(modelDirectory: corpus.model)
        let a = try await scribe.transcribe(file)
        let b = try await scribe.transcribe(file)
        #expect(a.text == b.text, "transcription is not deterministic")
        #expect(a.words == b.words, "word times are not deterministic")
    }

    /// Lengths chosen around the fixed 15 s window: shorter than one window,
    /// exactly one, one sample over, and several with a partial tail.
    @Test func lengthSweepAroundTheWindow() async throws {
        let corpus = try #require(Corpus())
        // The longest file gives the sweep room to reach a minute.
        var file = try #require(corpus.files.first)
        var full = try await AudioIO.decode(path: file.path, sampleRate: 16000)
        for candidate in corpus.files.dropFirst() {
            let samples = try await AudioIO.decode(path: candidate.path, sampleRate: 16000)
            if samples.count > full.count { full = samples; file = candidate }
        }
        let scribe = try Scribe(modelDirectory: corpus.model)
        print("\n  length sweep on \(file.lastPathComponent)")
        for seconds in [0.5, 1.0, 5.0, 14.9, 15.0, 15.1, 20.0, 30.0, 45.1, 60.0] {
            let count = Int(seconds * 16000)
            guard count <= full.count else { continue }
            let result = try await scribe.transcribe(samples: Array(full[0..<count]))
            check(result, label: "\(seconds)s", duration: seconds)
            let last = result.words.last?.start ?? 0
            print("    \(pad(String(format: "%.1fs", seconds), 8)) "
                  + "\(pad(String(result.words.count), 5)) words, "
                  + "last at \(String(format: "%.1f", last))s")
            #expect(last <= seconds + 0.5, "\(seconds)s: last word at \(last)s is past the audio")
        }
    }

    /// Silence and tones carry no speech, so an empty transcript is correct.
    /// What must not happen is a flood of invented words.
    @Test func nonSpeechDoesNotHallucinate() async throws {
        let corpus = try #require(Corpus())
        let scribe = try Scribe(modelDirectory: corpus.model)
        let cases: [(String, [Float])] = [
            ("silence 30s", [Float](repeating: 0, count: 16000 * 30)),
            ("quiet noise 30s", (0..<(16000 * 30)).map { _ in Float.random(in: -1e-4...1e-4) }),
            ("1 kHz tone 20s", (0..<(16000 * 20)).map {
                0.2 * sin(2 * .pi * 1000 * Float($0) / 16000) }),
        ]
        for (label, samples) in cases {
            let result = try await scribe.transcribe(samples: samples)
            let seconds = Double(samples.count) / 16000
            check(result, label: label, duration: seconds)
            print("    \(pad(label, 18)) \(result.words.count) words: "
                  + String(result.text.prefix(60)))
            #expect(Double(result.words.count) < seconds, "\(label): \(result.words.count) words from non-speech")
        }
    }

    /// Rates and channel counts the SDK is expected to normalize.
    @Test func acceptsOtherRates() async throws {
        let corpus = try #require(Corpus())
        let scribe = try Scribe(modelDirectory: corpus.model)
        let file = try #require(corpus.files.first)
        let base = try await AudioIO.decode(path: file.path, sampleRate: 16000)
        let native = try await scribe.transcribe(samples: base)
        for rate in [8000.0, 22050.0, 44100.0, 48000.0] {
            let resampled = Resample.linear(base, from: 16000, to: rate)
            let result = try await scribe.transcribe(samples: resampled, sampleRate: rate)
            check(result, label: "\(rate) Hz", duration: Double(base.count) / 16000)
            print("    \(pad(String(format: "%.0f Hz", rate), 10)) "
                  + "\(result.words.count) words (16 kHz gave \(native.words.count))")
            #expect(!result.words.isEmpty, "\(rate) Hz produced nothing")
        }
    }
}

private func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
}
#endif
