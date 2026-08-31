#if canImport(CoreML)
import CoreML
import Foundation
#endif
import DesertAnt

public enum CueError: Error, CustomStringConvertible, Sendable {
    case unsupportedPlatform
    case invalidModel(String)
    case invalidAudio(String)

    public var description: String {
        switch self {
        case .unsupportedPlatform:
            return "Cue requires Core ML and runs on Apple platforms only"
        case .invalidModel(let m): return "invalid model: \(m)"
        case .invalidAudio(let m): return "invalid audio: \(m)"
        }
    }
}

#if canImport(CoreML)

/// On-device voice activity detection: which parts of a recording contain
/// speech, to 10 ms, running entirely on the Neural Engine.
///
/// ```swift
/// let cue = try Cue()
/// let result = try await cue.detect(url)
/// for span in result.speech { print(span.start, span.end) }
/// print(result.speechRatio)
/// ```
///
/// The model downloads on first use and is cached; pass a `directory` to adopt
/// files you have already placed somewhere, or call ``download(progress:)`` to
/// fetch it ahead of time. It is 339 KiB.
///
/// Language-independent: it keys on acoustics rather than words, and was
/// evaluated across 14 languages. Music and singing are usually reported as
/// speech, which is what most callers segmenting a recording want; if you need
/// to tell them apart you need an audio-event model, not this one.
public final class Cue: @unchecked Sendable {

    // MARK: - Types

    /// A stretch of speech, in seconds from the start of the audio.
    public struct Span: Sendable, Equatable, Codable {
        public let start: Double
        public let end: Double
        public var duration: Double { end - start }

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    /// Precision / recall trade-off. `balanced` is the upstream default and the
    /// setting every published number was measured at.
    public enum Bias: Sendable {
        /// Strictest gate (threshold 0.6): fewest false alarms on noise and
        /// music, at the cost of clipping quiet speech.
        case precision
        /// Default gate (threshold 0.4).
        case balanced
        /// Loosest gate (threshold 0.25): catches quiet and distant speech,
        /// and more of the noise around it.
        case recall

        /// The probability threshold this preset maps to, exposed so a caller
        /// can reuse the value rather than hardcode it.
        public var speechThreshold: Float {
            switch self {
            case .precision: return 0.6
            case .balanced: return 0.4
            case .recall: return 0.25
            }
        }
    }

    /// Tuning for a single `detect(...)` call. Durations are in seconds; they
    /// are converted to frames at the model's 10 ms hop.
    public struct Options: Sendable {
        /// Preset that sets `speechThreshold`. Default `.balanced`.
        public var bias: Bias
        /// Overrides the preset's threshold. `nil` uses `bias`.
        public var speechThreshold: Float?
        /// Speech shorter than this is not reported. Default 0.2 s.
        public var minSpeechDuration: Double
        /// A pause shorter than this does not end a span, so a sentence is one
        /// span rather than one per word. Default 0.2 s.
        public var minSilenceDuration: Double
        /// Spans longer than this are split at their quietest frame, so a
        /// caller slicing audio never gets an unbounded chunk. Default 20 s.
        public var maxSpeechDuration: Double
        /// Widen every span by this much at each end, for cutting with a little
        /// air around the speech. Default 0.
        public var padding: Double

        public init(bias: Bias = .balanced,
                    speechThreshold: Float? = nil,
                    minSpeechDuration: Double = 0.2,
                    minSilenceDuration: Double = 0.2,
                    maxSpeechDuration: Double = 20,
                    padding: Double = 0) {
            self.bias = bias
            self.speechThreshold = speechThreshold
            self.minSpeechDuration = minSpeechDuration
            self.minSilenceDuration = minSilenceDuration
            self.maxSpeechDuration = maxSpeechDuration
            self.padding = padding
        }

        public static let `default` = Options()
    }

    /// What a detection produced.
    public struct Result: Sendable {
        /// Speech spans in order, non-overlapping.
        public let speech: [Span]
        /// Per-frame speech probability, one every ``frameDuration`` seconds.
        /// Useful for drawing a meter or applying your own thresholding; the
        /// spans in ``speech`` are what most callers want.
        public let probabilities: [Float]
        /// Seconds one probability covers (0.01).
        public let frameDuration: Double
        /// Length of the audio analysed.
        public let duration: Double
        /// Wall-clock time spent analysing it.
        public let processingTime: TimeInterval

        /// Total speech, in seconds.
        public var speechDuration: Double { speech.reduce(0) { $0 + $1.duration } }
        /// Fraction of the audio that is speech, in `0...1`.
        public var speechRatio: Double { duration > 0 ? speechDuration / duration : 0 }
        /// Whether any speech was found.
        public var containsSpeech: Bool { !speech.isEmpty }
        /// Seconds of audio processed per second of wall clock.
        public var realtimeFactor: Double {
            processingTime > 0 ? duration / processingTime : 0
        }

        /// The gaps between spans: everything not reported as speech.
        public func silence() -> [Span] {
            var out: [Span] = []
            var cursor = 0.0
            for s in speech {
                if s.start > cursor { out.append(Span(start: cursor, end: s.start)) }
                cursor = Swift.max(cursor, s.end)
            }
            if cursor < duration { out.append(Span(start: cursor, end: duration)) }
            return out
        }
    }

    // MARK: - Availability

    /// Whether the model is already on disk, so a caller can decide whether to
    /// show a download step.
    public static func isDownloaded(directory: String? = nil, cacheRoot: String? = nil) -> Bool {
        CueModel.isAvailable(directory: directory, cacheRoot: cacheRoot)
    }

    /// Fetch the model without loading it, for downloading during onboarding.
    @discardableResult
    public static func download(
        directory: String? = nil,
        cacheRoot: String? = nil,
        progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws -> String {
        try await CueModel.resolve(directory: directory, cacheRoot: cacheRoot,
                                   progress: progress).rootPath
    }

    // MARK: - Creation

    private let pipeline: Pipeline
    private let configuration: Configuration
    /// Audio rate the model expects. Input at another rate is resampled.
    public let sampleRate: Double
    /// Seconds covered by one probability (0.01).
    public let frameDuration: Double
    /// Filterbank of digital silence, computed once; pads the tail of a clip
    /// shorter than one model window.
    private let silenceFrame: [Float]

    /// Load the model, downloading it first if needed.
    ///
    /// The first load after a download pays a one-time Neural Engine
    /// specialization; hold onto the instance rather than making one per call.
    public convenience init(
        directory: String? = nil,
        cacheRoot: String? = nil,
        computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
        progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws {
        guard CueModel.supports(.current) else { throw CueError.unsupportedPlatform }
        let stored = try await CueModel.resolve(directory: directory, cacheRoot: cacheRoot,
                                                progress: progress)
        try self.init(modelDirectory: URL(fileURLWithPath: stored.rootPath),
                      computeUnits: computeUnits)
    }

    /// Load from a directory of model files you manage yourself, holding
    /// `cue.mlmodelc` and `cue_meta.json`.
    public init(modelDirectory: URL,
                computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let assets = try Assets(directory: modelDirectory, computeUnits: computeUnits)
        pipeline = Pipeline(assets: assets)
        configuration = assets.configuration
        sampleRate = Double(assets.configuration.sampleRate)
        frameDuration = assets.configuration.frameShiftSeconds
        // One window of digital silence, so the tail padding is a frame the
        // model could actually have seen.
        let quiet = [Float](repeating: 0,
                            count: assets.configuration.frameLengthSamples * 3)
        let (values, frames) = assets.frontend.features(quiet)
        silenceFrame = frames > 0
            ? Array(values[(frames / 2) * assets.configuration.mels ..<
                           (frames / 2 + 1) * assets.configuration.mels])
            : [Float](repeating: 0, count: assets.configuration.mels)
    }

    // MARK: - Detection

    /// Detect speech in mono samples at ``sampleRate``, normalised to -1...1.
    public func detect(samples: [Float],
                       options: Options = .default,
                       progress: @Sendable (Double) -> Void = { _ in }) throws -> Result {
        guard !samples.isEmpty else { throw CueError.invalidAudio("no samples") }
        let started = Date()
        let duration = Double(samples.count) / sampleRate

        // Kaldi's filterbank is defined on int16-scale audio, and the model was
        // trained on exactly that; feeding -1...1 makes every log-mel value
        // about 10.4 lower and the answer meaningless.
        var scaled = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count { scaled[i] = samples[i] * 32768 }

        let (features, frames) = pipeline.assets.frontend.features(scaled)
        guard frames > 0 else {
            throw CueError.invalidAudio(
                "needs at least \(configuration.frameLengthSamples) samples "
                    + "(\(String(format: "%.3f", Double(configuration.frameLengthSamples) / sampleRate)) s)")
        }
        let probs = try pipeline.probabilities(features: features, frames: frames,
                                               silenceFrame: silenceFrame,
                                               progress: progress)
        let spans = segment(probs, options: options, duration: duration)
        return Result(speech: spans, probabilities: probs,
                      frameDuration: frameDuration, duration: duration,
                      processingTime: Date().timeIntervalSince(started))
    }

    private func segment(_ probs: [Float], options: Options, duration: Double) -> [Span] {
        let hop = frameDuration
        func frames(_ seconds: Double) -> Int { Int((seconds / hop).rounded()) }
        let d = configuration.defaults
        let segmenter = Segmenter(
            smoothWindowFrames: d.smoothWindowFrames,
            speechThreshold: options.speechThreshold ?? options.bias.speechThreshold,
            minSpeechFrames: Swift.max(0, frames(options.minSpeechDuration)),
            maxSpeechFrames: Swift.max(0, frames(options.maxSpeechDuration)),
            minSilenceFrames: Swift.max(0, frames(options.minSilenceDuration)),
            mergeSilenceFrames: d.mergeSilenceFrames,
            extendSpeechFrames: d.extendSpeechFrames,
            frameShift: hop)
        let spans = segmenter.spans(segmenter.decisions(for: probs), duration: duration)
        guard options.padding > 0 else {
            return spans.map { Span(start: $0.start, end: $0.end) }
        }
        // Pad, then coalesce anything the padding made touch, so the result
        // stays non-overlapping and in order.
        var out: [Span] = []
        for s in spans {
            let padded = Span(start: Swift.max(0, s.start - options.padding),
                              end: Swift.min(duration, s.end + options.padding))
            if let last = out.last, padded.start <= last.end {
                out[out.count - 1] = Span(start: last.start,
                                          end: Swift.max(last.end, padded.end))
            } else {
                out.append(padded)
            }
        }
        return out
    }
}

#endif
