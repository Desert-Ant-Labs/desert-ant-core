#if canImport(Speech) && canImport(CoreMedia)
import CoreMedia
import Foundation
import Speech

@available(iOS 26, macOS 26, tvOS 26, visionOS 26, *)
extension SpeechTimestampRefiner {
    /// Extract per-word timings from a SpeechAnalyzer result's attributed text.
    func words(from text: AttributedString) -> [WordTiming] {
        var out: [WordTiming] = []
        for run in text.runs {
            guard let range = run.audioTimeRange else { continue }
            let t = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let start = CMTimeGetSeconds(range.start)
            out.append(WordTiming(text: t, start: start, end: start + CMTimeGetSeconds(range.duration)))
        }
        return out
    }

    /// Return the same attributed text with corrected `audioTimeRange`s using the provided audio.
    func refine(_ text: AttributedString, audio samples: [Float], sampleRate: Double = 16000) -> AttributedString {
        let fixed = refine(words(from: text), audio: samples, sampleRate: sampleRate)
        return Self.apply(fixed, to: text)
    }

    static func apply(_ words: [WordTiming], to text: AttributedString) -> AttributedString {
        var result = text
        var i = 0
        for run in text.runs {
            guard run.audioTimeRange != nil, i < words.count else { continue }
            let w = words[i]; i += 1
            let start = CMTime(seconds: w.start, preferredTimescale: 1_000_000)
            let dur = CMTime(seconds: max(0, w.end - w.start), preferredTimescale: 1_000_000)
            result[run.range].audioTimeRange = CMTimeRange(start: start, duration: dur)
        }
        return result
    }
}
#endif
