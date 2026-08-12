import DesertAnt
import Foundation
import Transcript

/// The stages a transcription reports.
public enum TranscriptionPhase: Sendable, Equatable {
    /// Fetching and loading the recognizer. Skipped once it is resident.
    case loadingModel
    /// Reading the speech.
    case transcribing
}

/// How far a transcription has got.
///
/// Phases run to completion in order and `fraction` restarts at 0 in each, so a
/// caller can weight them however its interface needs.
public struct TranscriptionProgress: Sendable, Equatable {
    public let phase: TranscriptionPhase
    /// 0...1 within ``phase``.
    public let fraction: Double

    public init(phase: TranscriptionPhase, fraction: Double) {
        self.phase = phase
        self.fraction = fraction
    }
}

/// Called with each ``TranscriptionProgress`` update, from whatever context the
/// work is on.
public typealias TranscriptionProgressHandler = @Sendable (TranscriptionProgress) -> Void

/// The words of a recording, and the language they were read as.
public struct Transcription: Sendable, Equatable {
    /// The recognized words, in the order they were spoken.
    public let words: [TimedWord]

    /// The language the recording was read as, which is the detected one where
    /// none was asked for and the resolved one where the request was regional.
    public let language: Locale

    public init(words: [TimedWord], language: Locale) {
        self.words = words
        self.language = language
    }
}

/// A source of timed words for a recording.
///
/// Adopt this to select clips from a transcript produced by a recognizer other
/// than the built-in ones.
public protocol Transcribing: Sendable {
    /// The languages this transcriber can read, in a stable order.
    var supportedLanguages: [Locale] { get async }

    /// Transcribes the audio of a recording.
    ///
    /// - Parameters:
    ///   - url: The audio or video file to transcribe.
    ///   - language: The language to transcribe as, or `nil` to detect it.
    ///   - progress: Called as the work proceeds.
    /// - Returns: The recognized words, and the language they were read as.
    /// - Throws: ``AutoEditError/unsupported(_:)`` if `language` is not one of
    ///   ``supportedLanguages``.
    func transcribe(
        _ url: URL,
        language: Locale?,
        progress: @escaping TranscriptionProgressHandler
    ) async throws -> Transcription
}

public extension Transcribing {
    /// Transcribes the audio of a recording, reporting no progress.
    func transcribe(_ url: URL, language: Locale? = nil) async throws -> Transcription {
        try await transcribe(url, language: language, progress: { _ in })
    }
}

/// An error thrown while producing an edit.
public enum AutoEditError: MessageError, Sendable {
    /// The recording contains no recognizable speech.
    case noSpeech
    /// The recording has no track of a kind the edit needs.
    case noPlayableTrack
    /// The operation has no implementation on this platform, or the
    /// transcriber cannot read the language it was asked for.
    case unsupported(String)
    /// The recording could not be written in a supported format.
    case exportFailed(String)

    public var message: String {
        switch self {
        case .noSpeech:
            "No speech was found in that recording."
        case .noPlayableTrack:
            "That recording has neither a picture nor a sound track to cut."
        case .unsupported(let what):
            "Unsupported: \(what)."
        case .exportFailed(let why):
            "The recording could not be written. \(why)"
        }
    }
}
