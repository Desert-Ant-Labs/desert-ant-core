import DesertAnt

/// Choosing which moments to keep: the discourse features the selector is fed,
/// candidate enumeration around saliency anchors, weighted interval scheduling
/// over the scored spans, and the near-duplicate cut. No model runs here - this
/// is the half of selection that would be identical on any runtime.
enum Pipeline {
    static let lookback = 8
    static let lookahead = 14
    static let minSentences = 3
    static let maxSentences = 10
    /// Drop a clip that repeats an already-kept one. Readers punish duplicates
    /// hard: the first search build shipped the same moment 2-3 times and lost
    /// ship-rank despite better individual clips.
    static let jaccardMax = 0.5

    /// Words per second, for turning a transcript into a duration. The corpus carries no
    /// timestamps, so this proxy is the only duration the pipeline has. Matches
    /// `python/construct.py`'s `WPS`.
    static let wordsPerSecond = 2.5

    /// An UPPER LIMIT on emitted moments, set by the video's DURATION. Never a quota: a
    /// transcript that supports fewer good moments emits fewer, and that is correct.
    ///
    /// **This is one definition shared with `python/construct.py`'s `clip_budget`, and it
    /// replaces a rule that disagreed with it.** The offline path capped at a literal 6 --
    /// which bound on 79% of the frozen holdout and on 98-99% of long and podcast, so every
    /// evaluated clip count was the ceiling rather than the model -- while this file capped at
    /// `max(min(n / 4, 12), 2)` and carried a comment claiming the two matched. They never did:
    /// identical input produced different clip counts on the two paths, and only one of them
    /// was ever evaluated.
    ///
    /// The numbers are measured, not chosen. Median Shorts the teacher emits, over 1,216 corpus
    /// videos: 8 under 5 minutes, 11 to 10, 13 to 30, 14 beyond. That curve is itself censored
    /// from above by the teacher prompt's own "Create 8 Shorts minimum and 15 Shorts maximum",
    /// so read the top of it as a property of the prompt as much as of the content.
    ///
    /// DURATION, not sentence count, because sentences per minute varies -- the same `n` is a
    /// different video at different speaking rates, and the measurement above is by duration.
    /// The old `n / 4` rule also floored at 2, which on a short video capped output at 2 clips
    /// where the pipeline could support about 3.
    static func budget(for transcript: [String]) -> Int {
        let words = transcript.reduce(0) { $0 + max(1, $1.split(separator: " ").count) }
        let minutes = Double(words) / wordsPerSecond / 60
        if minutes < 5 { return 8 }
        if minutes < 10 { return 11 }
        if minutes < 30 { return 13 }
        return 14
    }

    /// The effective ceiling: a caller's `limit` when given, otherwise the duration curve.
    ///
    /// **A limit set here is not the same as trimming the returned list, and the difference is
    /// both latency and content.** The anchor count is `budget * 4`, so the ceiling sizes the
    /// candidate pool and therefore the number of scorer passes — most of the runtime. Trimming
    /// afterwards pays for every clip and then discards some, which is what `Clips.clips(in:
    /// limit:)` used to do.
    ///
    /// The content differs too: weighted interval scheduling at budget k returns the
    /// highest-total NON-OVERLAPPING SET of size <= k, which is not generally the top k of the
    /// set it would return at a larger budget. Neither is wrong; they answer different
    /// questions. This one answers "the best k moments", which is what a bounded list wants.
    static func budget(for transcript: [String], limit: Int?) -> Int {
        guard let limit else { return budget(for: transcript) }
        return max(1, limit)
    }

    /// Every span worth scoring: around each of the most salient sentences, all
    /// runs of 3...10 sentences that contain it, starting up to 8 sentences
    /// before it and ending up to 14 after.
    ///
    /// `budget` is passed in rather than recomputed. It used to be derived here from `n` and
    /// again in `rank`, and the anchor count is `budget * 4`, so two derivations that ever
    /// disagreed would enumerate a pool the ranker never sized for.
    static func enumerateCandidates(count n: Int, saliency: [Double], budget: Int) -> [[Int]] {
        let anchors = saliency.enumerated().sorted { $0.element > $1.element }
            .prefix(max(budget * 4, 12)).map(\.offset)
        var seen = Set<[Int]>()
        for a in anchors where a < n {
            for lo in max(0, a - lookback)...a {
                for hi in a..<min(n, a + lookahead + 1)
                where (hi - lo + 1) >= minSentences && (hi - lo + 1) <= maxSentences {
                    seen.insert(Array(lo...hi))
                }
            }
        }
        return seen.sorted { ($0.first!, $0.last!) < ($1.first!, $1.last!) }
    }

    /// Scored candidates in, ranked non-overlapping moments out.
    static func rank(candidates: [[Int]], scores: [Double], transcript: [String],
                     limit: Int?) -> [Clip] {
        let spans = candidates.enumerated().map { (i, span) in (span.first!, span.last!, scores[i]) }
        let chosen = dedupe(
            selectNonOverlapping(spans, budget: budget(for: transcript, limit: limit)),
            transcript: transcript)
        let ranked = chosen.sorted { $0.2 > $1.2 }
        return ranked.enumerated().map { (i, span) in
            let ids = Array(span.0...span.1)
            let words = ids.reduce(0) { $0 + transcript[$1].split(separator: " ").count }
            return Clip(
                id: i,
                sentenceIDs: ids,
                text: ids.map { transcript[$0] }.joined(separator: " "),
                score: span.2,
                percentile: ranked.count > 1 ? 1.0 - Double(i) / Double(ranked.count - 1) : 1.0,
                estimatedDurationSec: Double(words) / 2.5)
        }
    }

    /// Weighted interval scheduling: choose the highest-scoring non-overlapping
    /// set of at most `budget` spans. Replaces claim-order greedy, under which a
    /// video's 4th-best moment could be truncated because the 1st-best anchor
    /// already took the sentence its hook needed.
    ///
    /// Near-ties are broken deterministically rather than on float noise, and that is
    /// load-bearing rather than tidy. The pool holds overlapping windows around one
    /// anchor, and the encoder truncates a span to a fixed token count, so two
    /// candidates differing only in trailing sentences can receive a bit-identical
    /// input and therefore an identical score. Measured on the frozen holdout, 27% of
    /// emitted clips had an exactly-tied rival. Under a bare `use > skip` over a sort
    /// on `hi` alone, which one a user sees turned on the last bit of a float: two
    /// numerically equivalent runs returned different clips, and a Core ML GPU run and
    /// an ANE run agreed on only 85% of spans in one stratum.
    ///
    /// Three things make it deterministic: a total order on `(hi, lo)` rather than `hi`
    /// alone, an epsilon so an equal score never displaces the incumbent, and preferring
    /// the smallest clip count among totals within that epsilon. The Python reference
    /// `clips-training/python/dp_select.py` does the same three and they must stay in
    /// step, or Swift and Python disagree on exactly these near-ties.
    static func selectNonOverlapping(_ spans: [(Int, Int, Double)], budget: Int)
        -> [(Int, Int, Double)] {
        let sorted = spans.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
        let eps = 1e-6
        guard !sorted.isEmpty, budget > 0 else { return [] }
        var prev = [Int](repeating: -1, count: sorted.count)
        for i in 0..<sorted.count {
            var j = i - 1
            while j >= 0 && sorted[j].1 >= sorted[i].0 { j -= 1 }
            prev[i] = j
        }
        let neg = -Double.greatestFiniteMagnitude
        var dp = [[Double]](repeating: [Double](repeating: neg, count: budget + 1),
                            count: sorted.count + 1)
        var take = [[Bool]](repeating: [Bool](repeating: false, count: budget + 1),
                            count: sorted.count + 1)
        for k in 0...budget { dp[0][k] = 0 }
        for i in 1...sorted.count {
            let p = prev[i - 1] + 1
            for k in 0...budget {
                let skip = dp[i - 1][k]
                let use = (k >= 1 && dp[p][k - 1] > neg / 2) ? dp[p][k - 1] + sorted[i - 1].2 : neg
                if use > skip + eps { dp[i][k] = use; take[i][k] = true } else { dp[i][k] = skip }
            }
        }
        // Smallest clip count whose total is within eps of the best: a tie between
        // k and k+1 clips means the extra clip earned nothing, so do not emit it.
        //
        // The maximum is taken first, deliberately. Advancing a running best only on
        // a jump greater than eps is NOT equivalent: several consecutive increments
        // can each fall under eps while summing to more than it, and the two rules
        // then differ by a clip. For totals [0, 1.0, 1.0000009, 1.0000018] the
        // running form yields k=3 where this yields k=2. That needs consecutive
        // candidates scoring under 1e-6, which this pool is now known to produce.
        let totals = dp[sorted.count]
        let best = totals.max() ?? 0
        let bestK = (0...budget).first { totals[$0] >= best - eps } ?? 0
        var out: [(Int, Int, Double)] = []
        var i = sorted.count, k = bestK
        while i > 0 && k > 0 {
            if take[i][k] { out.append(sorted[i - 1]); k -= 1; i = prev[i - 1] + 1 } else { i -= 1 }
        }
        return out.reversed()
    }

    /// Cut spans whose words repeat an already-kept span's past ``jaccardMax``.
    static func dedupe(_ spans: [(Int, Int, Double)], transcript: [String])
        -> [(Int, Int, Double)] {
        var kept: [(Int, Int, Double)] = []
        for s in spans {
            let a = Set(Array(s.0...s.1).flatMap { transcript[$0].split(separator: " ") })
            let clash = kept.contains { k in
                let b = Set(Array(k.0...k.1).flatMap { transcript[$0].split(separator: " ") })
                return Double(a.intersection(b).count) / Double(max(a.union(b).count, 1)) > jaccardMax
            }
            if !clash { kept.append(s) }
        }
        return kept
    }

    // MARK: discourse features

    /// EXACT port of `train_gen1.disc_feats`. Order and semantics must match
    /// training or the heads receive garbage in 5 of their 773 input dimensions:
    ///   [position, hookPatternCount, payoffPatternCount, endsWithQuestion, digitRatio]
    /// Note these are pattern COUNTS (how many of the list matched), not
    /// booleans, and the position comes FIRST - an earlier hand-written version
    /// had all five wrong.
    static let hookPatterns: [Pattern] = compile([
        "\\bhere'?s\\b", "nobody", "most people",
        "the (mistake|secret|truth|problem|reason)", "\\bwhat if\\b", "\\bwhy\\b",
        "\\bhow (to|i|we|you)\\b", "\\?",
        "\\b(never|always|everyone|no one|nobody)\\b",
        "\\b(biggest|worst|best|craziest|first|only|most)\\b",
    ])
    static let payoffPatterns: [Pattern] = compile([
        "\\bso\\b", "that'?s why", "the point", "which means", "turns out", "the result",
    ])

    private static func compile(_ patterns: [String]) -> [Pattern] {
        patterns.compactMap { try? Pattern($0).ignoresCase() }
    }

    static func discourseFeatures(_ sentence: String, position: Double) -> [Float] {
        let t = sentence.lowercased()
        func count(_ patterns: [Pattern]) -> Float {
            Float(patterns.reduce(0) { $0 + ($1.contains(in: t) ? 1 : 0) })
        }
        let endsQ: Float = t.trimmedWhitespace.hasSuffix("?") ? 1 : 0
        let digits = t.filter(\.isNumber).count
        let digitRatio = Float(digits) / Float(t.count + 1)
        return [Float(position), count(hookPatterns), count(payoffPatterns), endsQ, digitRatio]
    }
}

private extension String {
    /// Trim ASCII/Unicode whitespace without Foundation (absent on Android).
    var trimmedWhitespace: String {
        let scalars = unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, scalars[start].properties.isWhitespace { start = scalars.index(after: start) }
        while end > start {
            let prev = scalars.index(before: end)
            if scalars[prev].properties.isWhitespace { end = prev } else { break }
        }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }
}
