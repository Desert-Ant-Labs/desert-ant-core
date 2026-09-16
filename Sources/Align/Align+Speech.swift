#if canImport(Speech) && canImport(CoreMedia)
import CoreMedia
import DesertAnt
import Foundation
import Speech

/// Live refinement against audio that is still arriving: feed it the same audio you feed
/// SpeechAnalyzer, then refine each finalized result against what has been buffered.
///
/// A boundary whose +/-1.2 s context is not buffered yet keeps its input timestamp, so a
/// word refined late is never worse than the recognizer's own answer.
public final class StreamingRefiner: @unchecked Sendable {
    /// The un-gated refiner underneath, for callers who also have complete audio.
    public let align: Align
    let languageCode: String
    private let maxBufferedSeconds: Double

    // streaming ring buffer (absolute sample timeline)
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var completeAudio: [Float]?
    private var baseSample: Int = 0

    /// Create a streaming refiner for `locale`. Construction does no work and starts no
    /// download; the model loads on the first call that needs it.
    public convenience init(locale: Locale, directory: String? = nil, maxBufferedSeconds: Double = 30,
                            computeUnits: ComputeUnits = .all) {
        self.init(align: Align(directory: directory, computeUnits: computeUnits),
                  languageCode: locale.language.languageCode?.identifier ?? "",
                  maxBufferedSeconds: maxBufferedSeconds)
    }

    /// Create a streaming refiner over an `Align` you already hold, so one loaded model
    /// serves both the offline and the streaming path.
    public init(align: Align, languageCode: String, maxBufferedSeconds: Double = 30) {
        self.align = align
        self.languageCode = languageCode
        self.maxBufferedSeconds = maxBufferedSeconds
    }

    /// False means every `refine` here is a passthrough.
    public func isSupported() async throws -> Bool {
        try await align.isSupported(languageCode: languageCode)
    }

    /// Feed audio as it arrives (the same audio you give SpeechAnalyzer).
    public func appendAudio(_ samples: [Float], sampleRate: Double = 16000) async throws {
        let rate = try await align.model.value().assets.config.sample_rate
        let audio = sampleRate == Double(rate) ? samples
            : Resampler.toRate(samples, from: sampleRate, to: Double(rate))
        lock.withLock {
            completeAudio = nil
            buffer.append(contentsOf: audio)
            let cap = Int(maxBufferedSeconds * Double(rate))
            if buffer.count > cap {
                let drop = buffer.count - cap
                buffer.removeFirst(drop)
                baseSample += drop
            }
        }
    }

    /// Correct finalized `words` using buffered audio.
    public func refine(_ words: [WordTiming]) async throws -> [WordTiming] {
        guard !words.isEmpty else { return words }
        let rt = try await align.model.value()
        guard let langId = rt.assets.config.languages[Align.key(languageCode)].map(Int32.init) else {
            return words
        }
        let (fullAudio, audio, base) = lock.withLock {
            (completeAudio, completeAudio ?? buffer, completeAudio == nil ? baseSample : 0)
        }
        let (logmel, nFrames) = rt.frontend.logMel(audio)
        return try await Align.runCascade(rt, words, logmel: logmel, nFrames: nFrames, langId: langId,
                                          sampleOffset: base, streaming: fullAudio == nil)
    }

    /// Refine against a whole recording instead of the ring buffer: no boundary then lacks context.
    public func useCompleteAudio(_ samples: [Float], sampleRate: Double) async throws {
        let rate = try await align.model.value().assets.config.sample_rate
        let audio = sampleRate == Double(rate) ? samples
            : Resampler.toRate(samples, from: sampleRate, to: Double(rate))
        lock.withLock {
            completeAudio = audio
            buffer.removeAll(keepingCapacity: false)
            baseSample = 0
        }
    }

    /// Drop everything buffered, for the next recording.
    public func reset() {
        lock.withLock {
            buffer.removeAll(keepingCapacity: true)
            completeAudio = nil
            baseSample = 0
        }
    }
}

@available(iOS 26, macOS 26, tvOS 26, visionOS 26, *)
extension Align {
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
    func refine(_ text: AttributedString, audio samples: [Float], sampleRate: Double = 16000,
                languageCode: String) async throws -> AttributedString {
        let fixed = try await refine(words(from: text), audio: samples, sampleRate: sampleRate,
                                     languageCode: languageCode)
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
