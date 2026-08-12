import AVFoundation
import Foundation
import Transcript
import WhisperKit

/// Transcribes with Whisper, through Argmax's Core ML builds.
///
/// The build is downloaded on first use and cached. One is held in memory at a
/// time.
public actor WhisperTranscriber: Transcribing {
    /// Which Whisper build to run, smallest first.
    public enum Model: String, CaseIterable, Sendable {
        /// Whisper Tiny, roughly 75 MB.
        case fast
        /// Whisper Base, roughly 150 MB.
        case standard
        /// Whisper Large v3 Turbo, roughly 630 MB.
        case best

        /// Argmax's name for the build.
        ///
        /// English-only builds are used for English. The large build has none.
        func identifier(for language: Locale?) -> String {
            let english = language?.language.languageCode?.identifier == "en"
            return switch self {
            case .fast: english ? "tiny.en" : "tiny"
            case .standard: english ? "base.en" : "base"
            case .best: "large-v3-v20240930_626MB"
            }
        }
    }

    private let model: Model
    private var loaded: [String: WhisperKit] = [:]

    /// Creates a transcriber.
    ///
    /// - Parameter model: The build to run.
    public init(model: Model = .standard) {
        self.model = model
    }

    /// Downloads and loads the build without transcribing anything, which is
    /// most of the wait before a first transcript.
    ///
    /// - Parameters:
    ///   - language: The language the build will transcribe, which decides
    ///     whether an English-only build is used.
    ///   - progress: Called as the build is fetched and loaded.
    public func prepare(
        language: Locale? = nil,
        progress: @escaping TranscriptionProgressHandler = { _ in }
    ) async throws {
        _ = try Self.code(for: language)
        _ = try await pipeline(for: language, progress: progress)
    }

    /// The languages Whisper reads, in a stable order.
    public var supportedLanguages: [Locale] {
        Self.supportedLanguages
    }

    /// The same list without an instance.
    public static let supportedLanguages: [Locale] =
        whisperCodes.keys.sorted().map { Locale(identifier: $0) }

    // Whisper spells Javanese `jw`, which ICU canonicalizes to `jv`, so a
    // `Locale` made from Whisper's list does not spell its own code back.
    // Keyed by the canonical code, valued by Whisper's.
    private static let whisperCodes: [String: String] = Dictionary(
        Constants.languageCodes.map {
            (Locale(identifier: $0).language.languageCode?.identifier ?? $0, $0)
        },
        uniquingKeysWith: { min($0, $1) }
    )

    public func transcribe(
        _ url: URL,
        language: Locale?,
        progress: @escaping TranscriptionProgressHandler
    ) async throws -> Transcription {
        let code = try Self.code(for: language)
        let whisper = try await pipeline(for: language, progress: progress)

        // Whisper reports finished segments rather than a percentage, so how
        // far into the recording it has read is the fraction.
        let seconds = duration(of: url)
        whisper.segmentDiscoveryCallback = { segments in
            guard seconds > 0, let end = segments.map(\.end).max() else { return }
            progress(TranscriptionProgress(phase: .transcribing,
                                           fraction: min(1, Double(end) / seconds)))
        }
        defer { whisper.segmentDiscoveryCallback = nil }

        let results = try await whisper.transcribe(
            audioPath: url.path(percentEncoded: false),
            decodeOptions: DecodingOptions(
                task: .transcribe,
                language: code,
                detectLanguage: code == nil,
                skipSpecialTokens: true,
                wordTimestamps: true
            )
        )

        let words = results
            .flatMap(\.segments)
            .flatMap { $0.words ?? [] }
            .map { TimedWord(text: $0.word, start: Double($0.start), end: Double($0.end)) }
        guard !words.isEmpty else { throw AutoEditError.noSpeech }
        progress(TranscriptionProgress(phase: .transcribing, fraction: 1))

        let spoken = results.first?.language ?? code ?? Constants.defaultLanguageCode
        return Transcription(words: words, language: Locale(identifier: spoken))
    }

    /// The code to decode with, or `nil` to detect. Regions resolve to their
    /// language, so `nl-BE` reaches the Dutch decoder.
    ///
    /// - Throws: ``AutoEditError/unsupported(_:)`` when Whisper has no decoder
    ///   for the language. An unknown code is otherwise ignored by the decoder,
    ///   returning a transcript in a language nobody asked for.
    static func code(for language: Locale?) throws -> String? {
        guard let language else { return nil }
        guard let canonical = language.language.languageCode?.identifier,
              let code = whisperCodes[canonical]
        else {
            throw AutoEditError.unsupported("Whisper cannot transcribe \(language.identifier)")
        }
        return code
    }

    /// The recording's length in seconds, or zero where it cannot be read.
    private nonisolated func duration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
            return 0
        }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    private func pipeline(
        for language: Locale?,
        progress: @escaping TranscriptionProgressHandler
    ) async throws -> WhisperKit {
        let variant = model.identifier(for: language)
        if let ready = loaded[variant] { return ready }

        let folder = try await WhisperKit.download(variant: variant) { fetched in
            progress(TranscriptionProgress(phase: .loadingModel,
                                           fraction: fetched.fractionCompleted))
        }
        let whisper = try await WhisperKit(
            WhisperKitConfig(model: variant,
                             modelFolder: folder.path(percentEncoded: false),
                             verbose: false,
                             prewarm: false)
        )
        // One build resident at a time: the large one is over a gigabyte. What
        // is on disk stays, where another app on the same package can reuse it.
        loaded = [variant: whisper]
        return whisper
    }
}
