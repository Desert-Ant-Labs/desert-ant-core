import Clips
import Foundation
import Transcript

/// Turns a recording into the clips worth publishing from it.
///
/// Takes a transcript produced outside this SDK and selects its strongest
/// moments. Cutting the recording down to them, like transcribing it, happens
/// outside this SDK: `Clip.ranges(in:padding:)` gives the time spans to cut.
///
/// ```swift
/// let editor = AutoEdit(clips: Clips(directory: clipsModel, cacheRoot: nil))
/// let edit = try await editor.edit(of: transcription)
/// ```
///
/// To title the clips, pass them to `Titles` from the `Title` module:
///
/// ```swift
/// let cards = try await Titles(directory: titleModel).cards(for: edit.clips)
/// ```
public struct AutoEdit: Sendable {
    /// A recording's transcript, and the language it was read as.
    public struct Reading: Sendable {
        /// The sentences, numbered from zero.
        public let sentences: [Sentence]

        /// The language the recording was read as, detected where none was
        /// asked for.
        public let language: Locale
    }

    /// A recording's transcript and the clips selected from it.
    public struct Edit: Sendable {
        /// The transcript the clips address, and the language it was read as.
        public let reading: Reading

        /// The selected clips, highest scoring first.
        public let clips: [Clip]

        /// The sentences the clips address. `Clip.sentenceIDs` are positions
        /// in this array.
        public var transcript: [Sentence] { reading.sentences }
    }

    private let clips: Clips

    /// Creates an editor.
    ///
    /// - Parameter clips: The selection model.
    public init(clips: Clips) {
        self.clips = clips
    }

    /// Selects the clips worth publishing from a transcript.
    ///
    /// - Parameters:
    ///   - transcription: The recording's timed words, produced by whichever
    ///     recognizer transcribed it.
    ///   - limit: The greatest number of clips to select, or `nil` for the
    ///     model's own limit for the transcript's length.
    /// - Returns: The transcript and the clips selected from it.
    /// - Throws: ``AutoEditError/noSpeech`` if the transcription contains no
    ///   recognizable speech.
    public func edit(
        of transcription: Transcription,
        limit: Int? = nil
    ) async throws -> Edit {
        let reading = try reading(of: transcription)
        return Edit(
            reading: reading,
            clips: try await clips(in: reading.sentences, limit: limit)
        )
    }

    /// Shapes a transcription into sentences, so that a transcript can be kept
    /// and selected from again.
    ///
    /// - Parameter transcription: The recording's timed words.
    /// - Returns: The transcript, numbered from zero, and the language it was
    ///   read as.
    /// - Throws: ``AutoEditError/noSpeech`` if the transcription contains no
    ///   recognizable speech.
    public func reading(of transcription: Transcription) throws -> Reading {
        let sentences = Sentence.sentences(from: transcription.words)
        guard !sentences.isEmpty else { throw AutoEditError.noSpeech }
        return Reading(sentences: sentences, language: transcription.language)
    }

    /// Selects the clips worth publishing from a transcript.
    ///
    /// - Parameters:
    ///   - transcript: The sentences to select from.
    ///   - limit: The greatest number of clips to select, or `nil` for the
    ///     model's own limit for the transcript's length.
    /// - Returns: The clips, highest scoring first.
    public func clips(in transcript: [Sentence], limit: Int? = nil) async throws -> [Clip] {
        try await clips.clips(in: transcript.map(\.text), limit: limit)
    }
}
