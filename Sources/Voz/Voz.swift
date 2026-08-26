#if canImport(CoreML)
import CoreML
import Foundation
#endif
import DesertAnt

public enum VozError: Error, CustomStringConvertible, Sendable {
    case unsupportedPlatform
    case invalidModel(String)
    case invalidAudio(String)

    public var description: String {
        switch self {
        case .unsupportedPlatform:
            return "Voz requires Core ML and runs on Apple platforms only"
        case .invalidModel(let m): return "invalid model: \(m)"
        case .invalidAudio(let m): return "invalid audio: \(m)"
        }
    }
}

#if canImport(CoreML)

/// On-device speech recognition: a transcript with word-level timestamps,
/// running entirely on the Neural Engine.
///
/// ```swift
/// let voz = try await Voz()
/// let result = try await voz.transcribe(url) { print($0.fractionCompleted) }
/// print(result.text, result.words.first?.start ?? 0)
/// ```
///
/// The model downloads on first use and is cached; pass a `directory` to adopt
/// files you have already placed somewhere, or call ``download(progress:)`` to
/// fetch it ahead of time.
public actor Voz {

    /// How far along a transcription is, and what it has produced so far.
    public struct Progress: Sendable {
        /// 0...1 over the whole request.
        public let fractionCompleted: Double
    }

    public struct Result: Sendable {
        /// The full transcript.
        public let text: String
        /// Every word with the time it starts. Resolution is 80 ms.
        public let words: [Word]
        /// Length of the audio transcribed.
        public let duration: TimeInterval
        /// Wall-clock time spent transcribing it.
        public let processingTime: TimeInterval
        /// Seconds of audio processed per second of wall clock.
        public var realtimeFactor: Double {
            processingTime > 0 ? duration / processingTime : 0
        }
    }

    private let pipeline: Pipeline
    /// Audio rate the model expects. Input at another rate is resampled.
    public nonisolated let sampleRate: Double


    /// The languages the model was trained on, as ISO 639-1 codes.
    ///
    /// It does not detect which one it is hearing, and audio in a language that
    /// is not here produces confident nonsense rather than an error. A caller
    /// routing mixed input should name the language first (see `Ear`) and check
    /// it against this set.
    public static let supportedLanguages: Set<String> = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi",
        "fr", "hr", "hu", "it", "lt", "lv", "mt", "nl", "pl",
        "pt", "ro", "ru", "sk", "sl", "sv", "uk",
    ]

    // MARK: - Availability

    /// Whether the model is already on disk, so a caller can decide whether to
    /// show a download step.
    public static func isDownloaded(directory: String? = nil, cacheRoot: String? = nil) -> Bool {
        VozModel.isAvailable(directory: directory, cacheRoot: cacheRoot)
    }

    /// Fetch the model without loading it, for downloading during onboarding.
    ///
    /// Worth doing: the first load after a download pays a one-time Neural Engine
    /// specialization of roughly 20 s, and every load after it takes about
    /// 0.2 s. Doing both here keeps that cost off the first transcription.
    @discardableResult
    public static func download(
        directory: String? = nil,
        cacheRoot: String? = nil,
        progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws -> String {
        try await VozModel.resolve(directory: directory, cacheRoot: cacheRoot,
                                        progress: progress).rootPath
    }

    // MARK: - Creation

    /// Load the model, downloading it first if needed.
    public init(
        directory: String? = nil,
        cacheRoot: String? = nil,
        progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws {
        guard VozModel.supports(.current) else { throw VozError.unsupportedPlatform }
        let stored = try await VozModel.resolve(directory: directory, cacheRoot: cacheRoot,
                                                     progress: progress)
        try self.init(modelDirectory: URL(fileURLWithPath: stored.rootPath))
    }

    /// Load from a directory of model files you manage yourself.
    public init(modelDirectory: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let assets = try Assets(directory: modelDirectory, computeUnits: computeUnits)
        pipeline = try Pipeline(assets: assets)
        sampleRate = Double(assets.configuration.sampleRate)
    }

    // MARK: - Transcription

    /// Transcribe mono samples at ``sampleRate``.
    public func transcribe(
        samples: [Float],
        progress: @Sendable (Progress) -> Void = { _ in }
    ) throws -> Result {
        guard !samples.isEmpty else { throw VozError.invalidAudio("no samples") }
        var stream = ArrayAudioStream(samples)
        return try transcribe(stream: &stream,
                              duration: Double(samples.count) / sampleRate,
                              progress: progress)
    }

    /// Transcribe from a source that is read as it goes, so that a long
    /// recording does not have to be resident all at once.
    func transcribe(
        stream: inout some AudioStream,
        duration: Double,
        progress: @Sendable (Progress) -> Void
    ) throws -> Result {
        let started = Date()
        let (text, words) = try pipeline.run(stream: &stream) {
            progress(Progress(fractionCompleted: min(1, max(0, $0))))
        }
        progress(Progress(fractionCompleted: 1))
        guard !words.isEmpty || duration > 0 else {
            throw VozError.invalidAudio("no samples")
        }
        let bounded = words.map {
            $0.end <= duration ? $0
                : Word(text: $0.text, start: Swift.min($0.start, duration), end: duration)
        }
        return Result(text: text, words: bounded, duration: duration,
                      processingTime: Date().timeIntervalSince(started))
    }
}

#endif
