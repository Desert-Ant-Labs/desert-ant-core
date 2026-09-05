import Foundation
import Testing
import Transcript
@testable import Clips

/// The chapter construction's non-model half.
///
/// These mirror `python/test_partition.py` in clips-training deliberately, property for
/// property. The model is trained against the Python construction's behaviour, so the two
/// implementations drifting apart would show up as a quality difference with no obvious cause.
/// When one side changes, change both.
///
/// Two of the properties here - exhaustive coverage, and no chapter below the minimum duration
/// - are exactly what the remote endpoint this replaces fails to guarantee. They are the
/// feature, not defensive checks.
struct ChapterConstructionTests {
    private func timings(_ n: Int, per: TimeInterval = 5) -> ([TimeInterval], [TimeInterval]) {
        let starts = (0..<n).map { TimeInterval($0) * per }
        return (starts, starts.map { $0 + per })
    }

    private func sentences(_ n: Int, per: TimeInterval = 5) -> [Sentence] {
        (0..<n).map {
            Sentence(id: $0, text: "s\($0).",
                     start: TimeInterval($0) * per, end: TimeInterval($0) * per + per)
        }
    }

    /// The baseline the DP has to beat: take boundaries in descending logit order, keeping any
    /// that respects the minimum spacing against those already taken.
    private func greedy(logits: [Double], n: Int) -> [Range<Int>] {
        var taken = [0]
        for i in (1..<n).sorted(by: { logits[$0] > logits[$1] }) {
            guard logits[i] > 0 else { continue }
            guard n - i >= ChapterConstruction.minSentences else { continue }
            if taken.allSatisfy({ abs(i - $0) >= ChapterConstruction.minSentences }) {
                taken.append(i)
            }
        }
        taken.sort()
        return zip(taken, taken.dropFirst() + [n]).map { $0..<$1 }
    }

    /// COVERAGE IS STRUCTURAL. Every sentence lands in exactly one chapter.
    ///
    /// The backend drops groups under 10 s after the fact and reassigns nothing, so its output
    /// is not the partition its own prompt demanded - 22 orphaned sentences in the sample the
    /// training repo pins. Nothing here can produce that.
    @Test func partitionTilesTheTranscriptExactly() {
        let n = 200
        let (starts, ends) = timings(n)
        var logits = [Double](repeating: -3, count: n)
        for i in [0, 40, 90, 150] { logits[i] = 5 }

        let cuts = ChapterConstruction.partition(logits: logits, starts: starts, ends: ends)
        #expect(cuts.first?.lowerBound == 0)
        #expect(cuts.last?.upperBound == n)
        for (a, b) in zip(cuts, cuts.dropFirst()) {
            #expect(a.upperBound == b.lowerBound)
        }
        #expect(cuts.reduce(0) { $0 + $1.count } == n)
    }

    @Test func partitionFindsPlantedBoundaries() {
        let n = 200
        let (starts, ends) = timings(n)
        let planted = [0, 40, 90, 150]
        var logits = [Double](repeating: -6, count: n)
        for i in planted { logits[i] = 8 }

        let cuts = ChapterConstruction.partition(logits: logits, starts: starts, ends: ends,
                                                 lambda: 0.5)
        #expect(cuts.map(\.lowerBound) == planted)
    }

    @Test func noChapterBelowTheMinimumSentenceCount() {
        let n = 120
        let (starts, ends) = timings(n)
        var logits = [Double](repeating: -4, count: n)
        logits[50] = 9
        logits[51] = 9   // one sentence apart; a threshold would take both

        let cuts = ChapterConstruction.partition(logits: logits, starts: starts, ends: ends)
        #expect(cuts.allSatisfy { $0.count >= ChapterConstruction.minSentences })
    }

    /// Ten sentences spanning 2 s: long enough to clear the sentence floor, far too short to be
    /// a chapter. The backend would emit it, then delete it, then orphan its sentences.
    @Test func noChapterBelowTheMinimumDuration() {
        let n = 60
        var starts: [TimeInterval] = []
        var ends: [TimeInterval] = []
        var t: TimeInterval = 0
        for i in 0..<n {
            let per: TimeInterval = (30..<40).contains(i) ? 0.2 : 6
            starts.append(t)
            ends.append(t + per)
            t += per
        }
        var logits = [Double](repeating: -4, count: n)
        logits[30] = 9
        logits[40] = 9

        let cuts = ChapterConstruction.partition(logits: logits, starts: starts, ends: ends)
        for cut in cuts.dropLast() {
            #expect(ends[cut.upperBound - 1] - starts[cut.lowerBound] >= ChapterConstruction.minDuration)
        }
    }

    /// With every logit positive a threshold emits a boundary everywhere. Count must come from
    /// the shape penalty, not from the model.
    @Test func shapePenaltyControlsCountNotTheModel() {
        let n = 300
        let (starts, ends) = timings(n)
        let logits = [Double](repeating: 1, count: n)

        let loose = ChapterConstruction.partition(logits: logits, starts: starts, ends: ends,
                                                  lambda: 0.1)
        let tight = ChapterConstruction.partition(logits: logits, starts: starts, ends: ends,
                                                  lambda: 20)
        #expect(loose.count > tight.count)
        #expect(loose.count < n)
    }

    /// THE argument for the DP, as a measurement rather than a claim: it can never score below
    /// greedy on the shared objective, and in practice it usually beats it.
    @Test func dpNeverScoresBelowGreedyAndUsuallyBeatsIt() {
        var rng = SystemRandomNumberGenerator()
        _ = rng   // deterministic below; kept to document intent

        var seed: UInt64 = 11
        func next() -> Double {
            // xorshift, so the sweep is reproducible across platforms.
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return Double(seed % 10_000) / 10_000
        }

        var wins = 0
        let trials = 40
        for _ in 0..<trials {
            let n = 60 + Int(next() * 240)
            let (starts, ends) = timings(n, per: 2 + next() * 6)
            let logits = (0..<n).map { _ in -2 + (next() - 0.5) * 12 }

            let dp = ChapterConstruction.partition(logits: logits, starts: starts, ends: ends)
            let gr = greedy(logits: logits, n: n)
            let dpScore = ChapterConstruction.objective(dp, logits: logits, starts: starts, ends: ends)
            let grScore = ChapterConstruction.objective(gr, logits: logits, starts: starts, ends: ends)
            #expect(dpScore >= grScore - 1e-9)
            if dpScore > grScore + 1e-9 { wins += 1 }
        }
        #expect(wins > trials / 2)
    }

    @Test func shortTranscriptIsOneChapter() {
        let (starts, ends) = timings(6)
        let cuts = ChapterConstruction.partition(logits: [Double](repeating: 1, count: 6),
                                                 starts: starts, ends: ends)
        #expect(cuts == [0..<6])
    }

    @Test func emptyTranscriptYieldsNoChapters() {
        #expect(ChapterConstruction.partition(logits: [], starts: [], ends: []).isEmpty)
    }

    /// Must agree with `python/partition.py`'s `target_count`, which is where the model's
    /// notion of chapter rhythm comes from.
    @Test func targetCountIsSublinearAndClamped() {
        #expect(ChapterConstruction.targetCount(duration: 60) >= 2)
        #expect(ChapterConstruction.targetCount(duration: 10 * 3600) <= 24)
        #expect(ChapterConstruction.targetCount(duration: 4 * 600)
                < 4 * ChapterConstruction.targetCount(duration: 600))
        #expect(ChapterConstruction.targetCount(duration: 3600)
                > ChapterConstruction.targetCount(duration: 600))
    }

    @Test func chaptersCarryTextAndTimingsAndNoTitle() {
        let sents = sentences(20)
        let chapters = ChapterConstruction.chapters(from: [0..<10, 10..<20], sentences: sents)
        #expect(chapters.count == 2)
        #expect(chapters[0].start == sents[0].start)
        #expect(chapters[1].end == sents[19].end)
        #expect(chapters[0].text.hasPrefix("s0."))
        // Naming is the Title model's job; this repo must not invent one.
        #expect(chapters[0].title == nil)
        #expect(chapters[1].id == 1)
    }
}
