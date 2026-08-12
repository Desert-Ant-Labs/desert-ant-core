/// A word recognized in audio, and the span of the recording it occupies.
///
/// Times are in seconds from the start of the recording. `text` is preserved
/// exactly as the recognizer emitted it, including any leading whitespace.
public struct TimedWord: Sendable, Equatable {
    /// The recognized text, including surrounding whitespace.
    public let text: String

    /// The time the word begins, in seconds from the start of the recording.
    public let start: Double

    /// The time the word ends, in seconds from the start of the recording.
    ///
    /// Never earlier than `start`.
    public let end: Double

    /// The length of the word, in seconds.
    public var duration: Double { end - start }

    /// Creates a word spanning the given times.
    ///
    /// - Parameters:
    ///   - text: The recognized text.
    ///   - start: The start time, in seconds.
    ///   - end: The end time, in seconds. Clamped to no earlier than `start`.
    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = max(start, end)
    }

    /// A Boolean value indicating whether the word carries a usable time.
    ///
    /// Recognizers report a word they could not place with a negative or
    /// non-finite time.
    var isTimed: Bool { start.isFinite && end.isFinite && start >= 0 }
}
