import Foundation
import Transcript

/// One chapter of a video: a contiguous run of sentences and the time it spans.
///
/// `title` is always `nil` here. Naming a chapter is text generation and belongs to the Title
/// model, which already exposes exactly the call it needs (`Titles.describe(_:)`). The split
/// is not an inconvenience we inherited: the production backend this replaces also names
/// chapters with a separate per-chapter request, so the boundary is where it has always been.
public struct Chapter: Identifiable, Sendable, Equatable {
    /// Position in the video, from 0. Chapters are always returned in time order, never
    /// ranked, because a partition has no ranking - every chapter is kept.
    public let id: Int

    /// Sentence indices covered, as a half-open range into the transcript passed in.
    public let sentenceIDs: Range<Int>

    /// The chapter's transcript text, joined.
    public let text: String

    public let start: TimeInterval
    public let end: TimeInterval

    public var duration: TimeInterval { end - start }

    /// Set by `name(with:)`; `nil` from `chapters(in:)`.
    public var title: String?

    public init(id: Int, sentenceIDs: Range<Int>, text: String,
                start: TimeInterval, end: TimeInterval, title: String? = nil) {
        self.id = id
        self.sentenceIDs = sentenceIDs
        self.text = text
        self.start = start
        self.end = end
        self.title = title
    }
}

/// Turning per-sentence boundary scores into chapters. No model runs here.
///
/// This mirrors `python/partition.py` in the training repo and the two must not drift: the
/// model is trained against the Python construction's behaviour, and a divergence would show
/// up as a quality difference nobody could locate. The tests in `ChaptersTests.swift` pin the
/// same properties as `python/test_partition.py`.
///
/// WHY A DP RATHER THAN A THRESHOLD ON THE PROBABILITIES.
///
/// Whether sentence 40 should open a chapter depends on where the previous boundary landed. A
/// greedy left-to-right pass answers that with a decision it already made for unrelated local
/// reasons, which is the same mistake `Pipeline.selectNonOverlapping` exists to avoid on the
/// clips side. Measured over random inputs in the training repo, the DP beats greedy on the
/// shared objective in the large majority of cases and can never lose to it.
///
/// WHAT THE OBJECTIVE IS. For a set of chapter-start indices `S`, the per-sentence Bernoulli
/// log-likelihood reduces to `sum over S of logit(i)` plus a term constant in `S`. So the DP
/// maximises a sum of the model's RAW LOGITS at the chosen boundaries, minus a shape penalty.
/// It consumes pre-sigmoid values directly: there is no threshold and no calibration step.
///
/// WHY THE SHAPE PENALTY IS REQUIRED. Under the likelihood alone the best partition takes
/// every sentence with a positive logit, because each contributes independently. Count would
/// then be something the model emits rather than something the output guarantees - the failure
/// that made the previous generative pipeline produce 1-4 second fragments. The penalty is
/// what makes count a constraint.
public enum ChapterConstruction {
    /// Minimum sentences in a chapter. Matches the production prompt's "minimum of 5
    /// sentences per group", so the shape matches the labels the model learned from.
    public static let minSentences = 5

    /// Minimum chapter duration. Same value as the backend's `MINIMUM_SELECTION_DURATION`,
    /// but applied as a constraint on the SEARCH rather than as a post-filter.
    ///
    /// That difference is the bug fix. The backend drops short groups after the fact and
    /// reassigns nothing, so their sentences end up in no chapter at all - 22 orphaned
    /// sentences in the sample transcript the training repo pins a test against. Here a short
    /// chapter is never constructed, so there is nothing to orphan and the output tiles the
    /// transcript by construction.
    public static let minDuration: TimeInterval = 10

    /// Strength of the shape penalty, in logit units per squared log-ratio of duration to
    /// target. Must equal `python/partition.py`'s `LAMBDA`.
    ///
    /// PROVISIONAL, pending the blind read. Do not tune it against agreement with the backend:
    /// agreement is maximised by reproducing the backend's chapter count, and its count is one
    /// of the things this is meant to improve on.
    public static let lambda = 2.0

    /// How many chapters a video of this length should have.
    ///
    /// Sublinear in duration, because chapter count is bounded by how many things a video is
    /// ABOUT, and that does not grow linearly with how long it takes to say them. The backend
    /// effectively has a linear rule - it batches the transcript at a fixed token budget and
    /// groups each batch independently, with nothing ever seeing the whole video - which is why
    /// it emitted 25 chapters for a single podcast, with segments from 21 s to 567 s.
    public static func targetCount(duration: TimeInterval) -> Int {
        let minutes = max(duration, 1) / 60
        return max(2, min(24, Int((1.8 * minutes.squareRoot()).rounded())))
    }

    /// The best partition of a transcript into contiguous chapters.
    ///
    /// - Parameters:
    ///   - logits: per-sentence pre-sigmoid boundary scores from the chapter model.
    ///   - starts: per-sentence start times.
    ///   - ends: per-sentence end times.
    /// - Returns: half-open sentence ranges covering `0..<n` exactly, in time order.
    public static func partition(logits: [Double],
                                 starts: [TimeInterval],
                                 ends: [TimeInterval],
                                 lambda: Double = lambda,
                                 target: Int? = nil) -> [Range<Int>] {
        let n = logits.count
        guard n > 0, starts.count == n, ends.count == n else { return [] }
        guard n >= 2 * minSentences else { return [0..<n] }

        let duration = Swift.max(ends[n - 1] - starts[0], 1)
        let k = target ?? targetCount(duration: duration)
        let targetSeconds = duration / Double(Swift.max(k, 1))

        var dp = [Double](repeating: -.infinity, count: n + 1)
        var back = [Int](repeating: -1, count: n + 1)
        dp[0] = 0

        // Bound on how far back a predecessor can be. The shape penalty makes a chapter many
        // times the target duration unwinnable, so this only removes candidates that could not
        // have been chosen. It is expressed in SENTENCES so the bound survives a transcript
        // with degenerate timings.
        let maxSpan = Swift.max(minSentences,
                                Swift.min(n, 8 * n / Swift.max(k, 1) + minSentences))

        if n >= minSentences {
            for j in minSentences...n {
                let lower = Swift.max(0, j - maxSpan)
                let upper = j - minSentences
                if lower > upper { continue }
                for i in lower...upper {
                    guard dp[i] > -.infinity else { continue }
                    let segment = ends[j - 1] - starts[i]
                    if segment < minDuration && j < n { continue }
                    // Squared LOG ratio, so "twice too long" and "half too long" cost the
                    // same. A squared difference in seconds would not be symmetric that way.
                    let ratio = log(Swift.max(segment, 1e-3) / Swift.max(targetSeconds, 1e-3))
                    let score = dp[i] + logits[i] - lambda * ratio * ratio
                    if score > dp[j] {
                        dp[j] = score
                        back[j] = i
                    }
                }
            }
        }

        guard dp[n] > -.infinity else { return [0..<n] }

        var cuts: [Range<Int>] = []
        var j = n
        while j > 0 {
            let i = back[j]
            guard i >= 0 else { return [0..<n] }
            cuts.append(i..<j)
            j = i
        }
        return cuts.reversed()
    }

    /// Score a partition under the DP's own objective. Exposed so "the DP is optimal" is a
    /// checkable claim rather than a comment, and so the Swift and Python constructions can be
    /// compared on the same number.
    public static func objective(_ cuts: [Range<Int>],
                                 logits: [Double],
                                 starts: [TimeInterval],
                                 ends: [TimeInterval],
                                 lambda: Double = lambda,
                                 target: Int? = nil) -> Double {
        guard let last = cuts.last, let first = cuts.first else { return 0 }
        let duration = Swift.max(ends[last.upperBound - 1] - starts[first.lowerBound], 1)
        let k = target ?? targetCount(duration: duration)
        let targetSeconds = duration / Double(Swift.max(k, 1))
        var total = 0.0
        for cut in cuts {
            let segment = Swift.max(ends[cut.upperBound - 1] - starts[cut.lowerBound], 1e-3)
            let ratio = log(segment / Swift.max(targetSeconds, 1e-3))
            total += logits[cut.lowerBound] - lambda * ratio * ratio
        }
        return total
    }

    /// Materialise chapter records from a partition and the sentences behind it.
    public static func chapters(from cuts: [Range<Int>], sentences: [Sentence]) -> [Chapter] {
        cuts.enumerated().map { index, cut in
            Chapter(id: index,
                    sentenceIDs: cut,
                    text: sentences[cut].map(\.text).joined(separator: " "),
                    start: sentences[cut.lowerBound].start,
                    end: sentences[cut.upperBound - 1].end)
        }
    }
}
