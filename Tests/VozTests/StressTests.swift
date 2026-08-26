#if canImport(CoreML)
import AudioIO
import Foundation
import Testing

@testable import Voz

// A battery over real audio of varying length, rate and channel count, plus
// synthetic edge cases. Opt-in, because it needs the model and a corpus:
//
//   VOZ_MODEL_DIR=... VOZ_CORPUS=/path/to/audio swift test -c release \
//     --filter VozStress
//
// Each case asserts the invariants that should hold for *any* input, so a
// failure points at the implementation rather than at a WER target: word times
// must be ordered, land inside the audio, and agree with the transcript; the
// same input must produce the same output; and audio that carries speech must
// produce words.
//
// The corpus must hold only languages in `Voz.supportedLanguages`. This model
// covers 25 European languages, and on anything else it does not fail: it
// returns fluent-looking words in the wrong language. Korean audio yields a few
// hundred of them, and NVIDIA's own checkpoint does the same, so the coverage
// checks below would be measuring the density of that noise. Unsupported audio
// is a question for the caller's language ID, not for this suite.

private struct Corpus {
    let model: URL
    let files: [URL]

    init?() {
        let env = ProcessInfo.processInfo.environment
        guard let model = env["VOZ_MODEL_DIR"], let dir = env["VOZ_CORPUS"] else {
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

/// Whether the benchmark has somewhere to read from. A test that returns early
/// when its inputs are absent reports as passed, so this is a trait instead.
var benchmarkIsConfigured: Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["VOZ_BENCH"] != nil && environment["VOZ_MODEL_DIR"] != nil
}


/// The widest stretch between two words, as absolute times.
private func largestHole(_ words: [Word]) -> (Double, Double)? {
    var best: (Double, Double)?
    var widest = 0.0
    for (a, b) in zip(words, words.dropFirst()) where b.start - a.end > widest {
        widest = b.start - a.end
        best = (a.end, b.start)
    }
    return best
}


@Suite(.enabled(if: Corpus() != nil, "set VOZ_MODEL_DIR and VOZ_CORPUS"),
       .serialized)
struct VozStress {

    /// Invariants that must hold for every transcription, whatever the audio.
    private func check(_ result: Voz.Result, label: String, duration: TimeInterval) {
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
        let voz = try Voz(modelDirectory: corpus.model)
        print("\n  \(pad("file", 22)) \(pad("audio", 9)) \(pad("proc", 8)) "
              + "\(pad("RTFx", 7)) \(pad("words", 7)) \(pad("covered", 7)) "
              + "\(pad("lead", 8)) \(pad("hole", 9)) trail")
        for file in corpus.files {
            let samples = try await AudioIO.decode(path: file.path, sampleRate: 16000)
            let duration = Double(samples.count) / 16000
            let result = try await voz.transcribe(file)
            check(result, label: file.lastPathComponent, duration: duration)

            // Four numbers, not one. The old single `gap` folded the lead-in
            // together with the holes and never looked past the last word, which
            // hid both a legitimate music intro (reported as an 11.9 s hole) and
            // a French recording that stopped after 70 s of 547 and reported the
            // rest as silence. Every one of its other numbers looked healthy.
            let lead = result.words.first?.start ?? duration
            let trail = duration - (result.words.last?.end ?? 0)
            let covered = duration > 0 ? (result.words.last?.end ?? 0) / duration : 0
            // Silence between words, not start to start: the latter counts the
            // first word's own length as part of the hole.
            var interior = 0.0
            for (a, b) in zip(result.words, result.words.dropFirst()) {
                interior = max(interior, b.start - a.end)
            }
            print("  \(pad(file.lastPathComponent, 22)) "
                  + "\(pad(String(format: "%.1fs", duration), 9)) "
                  + "\(pad(String(format: "%.2fs", result.processingTime), 8)) "
                  + "\(pad(String(format: "%.0f", result.realtimeFactor), 7)) "
                  + "\(pad(String(result.words.count), 7)) "
                  + "\(pad(String(format: "%.0f%%", covered * 100), 7)) "
                  + "\(pad(String(format: "%.1fs", lead), 8)) "
                  + "\(pad(String(format: "%.1fs", interior), 9)) "
                  + String(format: "%.1fs", trail))
            // A window is 15 s, so a hole approaching that means one produced
            // nothing. The bar is deliberately below the window length: at 15 s
            // a lost window passes by a tenth of a second and the defect ships.
            if interior >= 8, let (from, to) = largestHole(result.words) {
                let lo = max(0, Int(from * 16000)), hi = min(samples.count, Int(to * 16000))
                let alone = try await voz.transcribe(samples: Array(samples[lo..<hi]))
                let detail = "\(file.lastPathComponent): \(interior) s the recognizer skipped "
                    + "here, but alone it reads as \"\(alone.text.prefix(60))\" - a window was lost"
                #expect(alone.words.isEmpty, "\(detail)")
            }
            // The transcript has to reach the end of the audio. This is the one
            // that catches a recogniser that stops early rather than one that
            // drops a window in the middle, and nothing else here can see it.
            if covered <= 0.95 {
                let lo = min(samples.count, Int((result.words.last?.end ?? 0) * 16000))
                let tail = try await voz.transcribe(samples: Array(samples[lo...]))
                let detail = "\(file.lastPathComponent): transcript covers "
                    + "\(Int(covered * 100))% of the audio, and the rest reads as "
                    + "\"\(tail.text.prefix(60))\" - the recognizer stopped early"
                #expect(tail.words.isEmpty, "\(detail)")
            }
            // A lead-in longer than a window means the first window produced
            // nothing. Shorter than that is a title card or music, which is not
            // this test's business.
            #expect(lead < 15,
                    "\(file.lastPathComponent): \(lead) s before the first word is a lost opening window")

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
        let voz = try Voz(modelDirectory: corpus.model)
        let a = try await voz.transcribe(file)
        let b = try await voz.transcribe(file)
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
        let voz = try Voz(modelDirectory: corpus.model)
        print("\n  length sweep on \(file.lastPathComponent)")
        for seconds in [0.5, 1.0, 5.0, 14.9, 15.0, 15.1, 20.0, 30.0, 45.1, 60.0] {
            let count = Int(seconds * 16000)
            guard count <= full.count else { continue }
            let result = try await voz.transcribe(samples: Array(full[0..<count]))
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
        let voz = try Voz(modelDirectory: corpus.model)
        let cases: [(String, [Float])] = [
            ("silence 30s", [Float](repeating: 0, count: 16000 * 30)),
            ("quiet noise 30s", (0..<(16000 * 30)).map { _ in Float.random(in: -1e-4...1e-4) }),
            ("1 kHz tone 20s", (0..<(16000 * 20)).map {
                0.2 * sin(2 * .pi * 1000 * Float($0) / 16000) }),
        ]
        for (label, samples) in cases {
            let result = try await voz.transcribe(samples: samples)
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
        let voz = try Voz(modelDirectory: corpus.model)
        let file = try #require(corpus.files.first)
        let base = try await AudioIO.decode(path: file.path, sampleRate: 16000)
        let native = try await voz.transcribe(samples: base)
        for rate in [8000.0, 22050.0, 44100.0, 48000.0] {
            let resampled = Resample.linear(base, from: 16000, to: rate)
            let result = try await voz.transcribe(samples: resampled, sampleRate: rate)
            check(result, label: "\(rate) Hz", duration: Double(base.count) / 16000)
            print("    \(pad(String(format: "%.0f Hz", rate), 10)) "
                  + "\(result.words.count) words (16 kHz gave \(native.words.count))")
            #expect(!result.words.isEmpty, "\(rate) Hz produced nothing")
        }
    }

    /// Transcribe every file in a directory, reporting throughput and dumping
    /// the text for scoring. Set VOZ_BENCH to the directory.
    ///
    /// The files this is aimed at are long on purpose. A ten-minute file
    /// crosses about forty window boundaries, so the merge logic is exercised
    /// forty times per language rather than not at all, which is what a corpus
    /// of ten-second utterances would measure.
    @Test(.enabled(if: benchmarkIsConfigured, "set VOZ_BENCH and VOZ_MODEL_DIR"))
    func benchmarkDirectory() async throws {
        let environment = ProcessInfo.processInfo.environment
        // Force-unwrapped rather than guarded: the trait above is what decides
        // whether this runs, and a guard here would let a misconfigured run
        // report a pass while measuring nothing.
        let dir = environment["VOZ_BENCH"]!
        let models = environment["VOZ_MODEL_DIR"]!
        let root = URL(fileURLWithPath: dir)
        let files = try FileManager.default
            .contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { ["wav", "flac", "m4a", "mp3"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let voz = try Voz(modelDirectory: URL(fileURLWithPath: models))
        for file in files {
            // Deliberately does not decode the file here. Doing so to work out
            // the duration would hold the whole recording in memory and hide
            // the very thing the streaming path exists to avoid.
            let result = try await voz.transcribe(file)
            let duration = result.duration
            let name = file.deletingPathExtension().lastPathComponent
            try? result.text.write(to: root.appendingPathComponent(name + ".hyp"),
                                   atomically: true, encoding: .utf8)
            if environment["VOZ_WORDS"] != nil {
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

@Suite("VozAudioStream", .enabled(if: Corpus() != nil, "set VOZ_MODEL_DIR and VOZ_CORPUS"))
struct VozAudioStreamTests {
    /// The streaming reader must deliver exactly what decoding the whole file
    /// delivers. It is easy for a chunked reader to lose audio at a chunk
    /// boundary and still look healthy, because the transcript stays readable.
    @Test func streamMatchesWholeFileDecode() async throws {
        let corpus = Corpus()!
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
