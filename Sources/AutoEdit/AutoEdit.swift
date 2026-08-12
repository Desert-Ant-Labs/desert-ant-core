import Clips
import Foundation
import Transcript

/// Turns a recording into the clips worth publishing from it.
///
/// Transcribes the recording, selects its strongest moments, and cuts the
/// source down to them.
///
/// ```swift
/// let editor = AutoEdit(clips: Clips(directory: clipsModel, cacheRoot: nil),
///                       transcriber: WhisperTranscriber(model: .best))
/// let edit = try await editor.edit(of: video)
/// for clip in edit.clips {
///     try await editor.write(clip, of: video, in: edit, to: folder.appending(path: "\(clip.id).mp4"))
/// }
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
    private let transcriber: any Transcribing

    /// Creates an editor.
    ///
    /// - Parameters:
    ///   - clips: The selection model.
    ///   - transcriber: The source of timed words.
    public init(clips: Clips, transcriber: any Transcribing) {
        self.clips = clips
        self.transcriber = transcriber
    }

    /// Transcribes a recording and selects the clips worth publishing.
    ///
    /// - Parameters:
    ///   - recording: The audio or video file to edit.
    ///   - language: The language to transcribe as, or `nil` to detect it.
    ///   - limit: The greatest number of clips to select, or `nil` for the
    ///     model's own limit for the transcript's length.
    /// - Returns: The transcript and the clips selected from it.
    /// - Throws: ``AutoEditError/noSpeech`` if the recording contains no
    ///   recognizable speech, or ``AutoEditError/unsupported(_:)`` if the
    ///   transcriber cannot read `language`.
    public func edit(
        of recording: URL,
        language: Locale? = nil,
        limit: Int? = nil,
        progress: @escaping TranscriptionProgressHandler = { _ in }
    ) async throws -> Edit {
        let reading = try await transcript(of: recording, language: language, progress: progress)
        return Edit(
            reading: reading,
            clips: try await clips(in: reading.sentences, limit: limit)
        )
    }

    /// Transcribes a recording, so that a transcript can be kept and selected
    /// from again without transcribing a second time.
    ///
    /// - Parameters:
    ///   - recording: The audio or video file to transcribe.
    ///   - language: The language to transcribe as, or `nil` to detect it.
    /// - Returns: The transcript, numbered from zero, and the language it was
    ///   read as.
    /// - Throws: ``AutoEditError/noSpeech`` if the recording contains no
    ///   recognizable speech, or ``AutoEditError/unsupported(_:)`` if the
    ///   transcriber cannot read `language`.
    public func transcript(
        of recording: URL,
        language: Locale? = nil,
        progress: @escaping TranscriptionProgressHandler = { _ in }
    ) async throws -> Reading {
        let read = try await transcriber.transcribe(recording, language: language, progress: progress)
        let sentences = Sentence.sentences(from: read.words)
        guard !sentences.isEmpty else { throw AutoEditError.noSpeech }
        return Reading(sentences: sentences, language: read.language)
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

    /// Cuts a clip out of the recording it was selected from.
    ///
    /// - Parameters:
    ///   - clip: The clip to write.
    ///   - recording: The recording the clip was selected from.
    ///   - edit: The edit the clip belongs to.
    ///   - destination: Where to write the result. A file already at this path
    ///     is left alone and a numbered name is used instead.
    ///   - padding: Time added to both ends of every span, in seconds.
    /// - Returns: The path written.
    @discardableResult
    public func write(
        _ clip: Clip,
        of recording: URL,
        in edit: Edit,
        to destination: URL,
        padding: Double = 0.15
    ) async throws -> URL {
        try await VideoIO.write(
            recording,
            ranges: clip.ranges(in: edit.transcript, padding: padding),
            to: destination
        )
    }
}
