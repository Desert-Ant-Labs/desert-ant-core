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
            // A window is 15 s, so a gap approaching that means one produced
            // nothing. The bar is deliberately below the window length: at 15 s
            // a lost window passes by a tenth of a second and the defect ships.
            #expect(gap < 8, "\(file.lastPathComponent): \(gap) s without a word suggests a window decoded to nothing")

            // Ends have to be usable for cutting: after the word starts, before
            // the file ends, and never running past where the next word begins.
            for (a, b) in zip(result.words, result.words.dropFirst()) {
                #expect(a.end >= a.start, "\(file.lastPathComponent): \(a.text) ends before it starts")
                #expect(a.end <= b.start + 1e-6,
                        "\(file.lastPathComponent): \(a.text) runs past the start of \(b.text)")
            }
            if let last = result.words.last {
                #expect(last.end <= duration + 1,
                        "\(file.lastPathComponent): last word ends after the audio does")
            }

            // Speech runs at a few words a second, so anything under one word
            // per two seconds means audio went missing rather than that the
            // speaker was terse. Without this, a bug that dropped everything
            // past the first batch of windows halved a half-hour transcript and
            // the suite stayed green, because what remained read perfectly.
            if !result.words.isEmpty {
                #expect(Double(result.words.count) / duration > 0.5,
                        "\(file.lastPathComponent): \(result.words.count) words in \(duration) s is too few to be the whole file")
            }
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

    /// Transcribe every file in a directory, reporting throughput and dumping
    /// the text for scoring. Set SCRIBE_BENCH to the directory.
    ///
    /// The files this is aimed at are long on purpose. A ten-minute file
    /// crosses about forty window boundaries, so the merge logic is exercised
    /// forty times per language rather than not at all, which is what a corpus
    /// of ten-second utterances would measure.
    @Test func benchmarkDirectory() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let dir = environment["SCRIBE_BENCH"],
              let models = environment["SCRIBE_MODEL_DIR"]
        else { return }
        let root = URL(fileURLWithPath: dir)
        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { ["wav", "flac", "m4a", "mp3"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let scribe = try Scribe(modelDirectory: URL(fileURLWithPath: models))
        for file in files {
            // Deliberately does not decode the file here. Doing so to work out
            // the duration would hold the whole recording in memory and hide
            // the very thing the streaming path exists to avoid.
            let result = try await scribe.transcribe(file)
            let duration = result.duration
            let name = file.deletingPathExtension().lastPathComponent
            try? result.text.write(to: root.appendingPathComponent(name + ".hyp"),
                                   atomically: true, encoding: .utf8)
            if environment["SCRIBE_WORDS"] != nil {
                let times = result.words.map {
                    ["text": $0.text, "start": "\($0.start)", "end": "\($0.end)"]
                }
                if let data = try? JSONSerialization.data(withJSONObject: times) {
                    try? data.write(to: root.appendingPathComponent(name + ".words"))
                }
            }
            print("BENCH\t\(name)\t\(duration)\t\(result.processingTime)"
                  + "\t\(result.realtimeFactor)\t\(result.words.count)")
        }
    }
}

private func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)

}

@Suite("ScribeAudioStream")
struct ScribeAudioStreamTests {
    /// The streaming reader must deliver exactly what decoding the whole file
    /// delivers. It is easy for a chunked reader to lose audio at a chunk
    /// boundary and still look healthy, because the transcript stays readable.
    @Test func streamMatchesWholeFileDecode() async throws {
        guard let corpus = Corpus() else { return }
        for file in corpus.files {
            let whole = try await AudioIO.decode(path: file.path, sampleRate: 16000)
            var stream = try FileAudioStream(url: file, sampleRate: 16000)
            var streamed: [Float] = []
            while try stream.read(1 << 16, into: &streamed) > 0 {}
            let name = file.lastPathComponent
            #expect(abs(streamed.count - whole.count) <= 16000 / 100,
                    "\(name): streamed \(streamed.count) samples, whole file has \(whole.count)")
            let n = Swift.min(streamed.count, whole.count)
            var worst: Float = 0
            for i in Swift.stride(from: 0, to: n, by: 7) {
                worst = Swift.max(worst, abs(streamed[i] - whole[i]))
            }
            #expect(worst < 1e-3, "\(name): samples differ by \(worst)")
        }
    }
}
#endif
