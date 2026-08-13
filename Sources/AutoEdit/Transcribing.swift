import DesertAnt
import Foundation
import Transcript

/// The words of a recording, and the language they were read as.
///
/// Transcription itself happens outside this SDK; bring the timed words from
/// whichever recognizer produced them.
public struct Transcription: Sendable, Equatable {
    /// The recognized words, in the order they were spoken.
    public let words: [TimedWord]

    /// The language the recording was read as.
    public let language: Locale

    public init(words: [TimedWord], language: Locale) {
        self.words = words
        self.language = language
    }
}

/// An error thrown while producing an edit.
public enum AutoEditError: MessageError, Sendable {
    /// The transcript contains no recognizable speech.
    case noSpeech
    /// The recording has no track of a kind the edit needs.
    case noPlayableTrack
    /// The operation has no implementation on this platform.
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
