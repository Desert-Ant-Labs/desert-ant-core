/// A sentence of transcribed speech, and the span of the recording it occupies.
public struct Sentence: Identifiable, Sendable, Equatable {
    /// The sentence's position in the transcript, numbered from zero.
    ///
    /// Clip selection identifies sentences by this index, so a transcript
    /// reordered or renumbered after selection resolves to different audio.
    public let id: Int

    /// The sentence text, with leading and trailing whitespace removed.
    public let text: String

    /// The time the sentence begins, in seconds from the start of the recording.
    public let start: Double

    /// The time the sentence ends, in seconds from the start of the recording.
    public let end: Double

    /// The length of the sentence, in seconds.
    public var duration: Double { end - start }

    /// Creates a sentence spanning the given times.
    ///
    /// - Parameters:
    ///   - id: The sentence's position in the transcript.
    ///   - text: The sentence text.
    ///   - start: The start time, in seconds.
    ///   - end: The end time, in seconds. Clamped to no earlier than `start`.
    public init(id: Int, text: String, start: Double, end: Double) {
        self.id = id
        self.text = text
        self.start = start
        self.end = max(start, end)
    }
}

public extension Sentence {
    /// Groups a recognizer's timed words into sentences.
    ///
    /// A sentence ends at terminal punctuation. Speech transcribed without
    /// punctuation is broken at `runOnLimit` characters instead, so that a
    /// transcript always presents more than one sentence to choose between.
    ///
    /// Each sentence spans from the start of its first placed word to the end
    /// of its last. Words the recognizer could not place contribute their text
    /// but not their times.
    ///
    /// - Parameters:
    ///   - words: The recognized words, in the order they were spoken.
    ///   - runOnLimit: The character count at which unpunctuated speech is
    ///     broken into a new sentence.
    /// - Returns: The sentences, numbered from zero. Empty if `words` contains
    ///   no text.
    static func sentences(from words: [TimedWord], runOnLimit: Int = 320) -> [Sentence] {
        var sentences: [Sentence] = []
        var pending = Pending(runOnLimit: runOnLimit)

        for word in words {
            if pending.isEmpty, word.text.allSatisfy(\.isWhitespace) { continue }

            pending.append(word)
            guard pending.closesSentence else { continue }
            if let sentence = pending.take(id: sentences.count) { sentences.append(sentence) }
        }

        if let sentence = pending.take(id: sentences.count) { sentences.append(sentence) }
        return sentences
    }
}

/// Accumulates words until they make a sentence.
private struct Pending {
    let runOnLimit: Int
    private var text = ""
    private var start: Double?
    private var end = 0.0

    init(runOnLimit: Int) { self.runOnLimit = runOnLimit }

    var isEmpty: Bool { start == nil }

    var closesSentence: Bool {
        let trimmed = text.trimmed
        guard let last = trimmed.last else { return false }
        // A lone terminator is punctuation the recognizer emitted as its own word.
        return ".!?…".contains(last) ? trimmed.count > 1 : trimmed.count >= runOnLimit
    }

    mutating func append(_ word: TimedWord) {
        text += word.text
        guard word.isTimed else { return }
        if start == nil { start = word.start }
        end = word.end
    }

    mutating func take(id: Int) -> Sentence? {
        defer { self = Pending(runOnLimit: runOnLimit) }
        let trimmed = text.trimmed
        guard !trimmed.isEmpty, let start else { return nil }
        return Sentence(id: id, text: trimmed, start: start, end: end)
    }
}

private extension String {
    var trimmed: String {
        String(drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
    }
}
