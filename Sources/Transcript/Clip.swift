/// A span of a recording, in seconds.
public struct TimeRange: Sendable, Equatable {
    /// The time the span begins, in seconds from the start of the recording.
    public let start: Double

    /// The time the span ends, in seconds from the start of the recording.
    public let end: Double

    /// The length of the span, in seconds.
    public var duration: Double { end - start }

    /// Creates a span between the given times.
    ///
    /// - Parameters:
    ///   - start: The start time, in seconds.
    ///   - end: The end time, in seconds. Clamped to no earlier than `start`.
    public init(start: Double, end: Double) {
        self.start = start
        self.end = max(start, end)
    }
}

/// A set of transcript sentences selected as a moment worth publishing.
///
/// Selection returns clips in descending order of `score`, and no two clips
/// share a sentence.
public struct Clip: Identifiable, Sendable, Equatable {
    /// The clip's rank in the selected set, where `0` is the highest scoring.
    public let id: Int

    /// The positions of the sentences that make up the clip, in ascending order.
    public let sentenceIDs: [Int]

    /// The clip's sentences, joined with spaces.
    public let text: String

    /// The score the model gave the clip.
    ///
    /// Comparable only among clips selected from the same transcript. Use
    /// `percentile` to compare across transcripts or to apply a threshold.
    public let score: Double

    /// The clip's rank within its transcript, from `0` to `1`.
    public let percentile: Double

    /// The estimated spoken length of `text`, in seconds.
    ///
    /// Estimated from word count. For the length the clip plays for, call
    /// `duration(in:padding:)`.
    public let estimatedDurationSec: Double

    /// Creates a clip.
    ///
    /// - Parameters:
    ///   - id: The clip's rank in the selected set.
    ///   - sentenceIDs: The positions of the sentences the clip contains.
    ///   - text: The clip's sentences, joined with spaces.
    ///   - score: The score the model gave the clip.
    ///   - percentile: The clip's rank within its transcript, from `0` to `1`.
    ///   - estimatedDurationSec: The estimated spoken length of `text`.
    public init(id: Int, sentenceIDs: [Int], text: String, score: Double,
                percentile: Double, estimatedDurationSec: Double) {
        self.id = id
        self.sentenceIDs = sentenceIDs
        self.text = text
        self.score = score
        self.percentile = percentile
        self.estimatedDurationSec = estimatedDurationSec
    }
}

public extension Clip {
    /// Returns the spans of the recording the clip plays.
    ///
    /// Sentences spoken without a gap between them produce a single span, and
    /// sentences separated by a pause produce one span each, so that the pause
    /// is cut rather than played. Spans that overlap once padded are combined.
    ///
    /// Each end is padded by half the silence before the neighbouring sentence,
    /// up to `padding`. Speech that runs straight into the next sentence takes
    /// none, so a cut never reaches into a neighbouring word, while word
    /// boundaries accurate only to tens of milliseconds are still covered
    /// wherever there is room.
    ///
    /// Sentence positions absent from `transcript` are ignored.
    ///
    /// - Parameters:
    ///   - transcript: The sentences the clip was selected from.
    ///   - padding: The greatest time to add to either end of a span, in
    ///     seconds.
    /// - Returns: The spans to play, in ascending order of `start`.
    func ranges(in transcript: [Sentence], padding: Double = 0.15) -> [TimeRange] {
        let byID = Dictionary(transcript.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let spans = sentenceIDs.sorted().compactMap { id -> TimeRange? in
            guard let sentence = byID[id] else { return nil }
            let before = byID[id - 1].map { sentence.start - $0.end } ?? sentence.start
            let after = byID[id + 1].map { $0.start - sentence.end } ?? .infinity
            return TimeRange(start: max(0, sentence.start - Self.share(of: before, upTo: padding)),
                             end: sentence.end + Self.share(of: after, upTo: padding))
        }

        return spans.reduce(into: []) { merged, span in
            guard let last = merged.last, span.start <= last.end else {
                merged.append(span)
                return
            }
            merged[merged.count - 1] = TimeRange(start: last.start, end: max(last.end, span.end))
        }
    }

    /// Half of a silence, up to `limit`. Zero where neighbouring speech runs
    /// straight in, and the full `limit` where nothing follows.
    private static func share(of gap: Double, upTo limit: Double) -> Double {
        guard gap > 0 else { return 0 }
        return gap.isFinite ? min(limit, gap / 2) : limit
    }

    /// Returns the length the clip plays for, in seconds.
    ///
    /// The total of the clip's spans, excluding any pauses cut between them.
    ///
    /// - Parameters:
    ///   - transcript: The sentences the clip was selected from.
    ///   - padding: Time added to both ends of every span, in seconds.
    func duration(in transcript: [Sentence], padding: Double = 0.15) -> Double {
        ranges(in: transcript, padding: padding).reduce(0) { $0 + $1.duration }
    }
}
