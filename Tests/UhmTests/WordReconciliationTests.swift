import Testing
@testable import Uhm

@Suite struct WordReconciliationTests {
    // MARK: - Helpers

    private func w(_ start: Double, _ end: Double, _ word: String = "x") -> WordRange {
        WordRange(start: start, end: end, word: word)
    }

    private func f(_ start: Double, _ end: Double, type: Uhm.FillerType? = .um) -> Uhm.Detection {
        Uhm.Detection(start: start, end: end, confidence: 0.9, type: type)
    }

    // MARK: - Geometry rules (one filler, one word)

    @Test func noFillersReturnsInputUnchanged() {
        let words = [w(0, 1, "hi"), w(2, 3, "there")]
        let out = Uhm.reconcileWords(words, fillers: [])
        #expect(out == words)
    }

    @Test func noOverlapPassesThrough() {
        let out = Uhm.reconcileWords([w(0, 1, "hi")], fillers: [f(2, 3)])
        #expect(out == [w(0, 1, "hi")])
    }

    @Test func wordFullyInsideFillerIsDropped() {
        // Whisper transcribed the filler as a word — drop it.
        let out = Uhm.reconcileWords([w(2.1, 2.7, "uh")], fillers: [f(2.0, 3.0)])
        #expect(out == [])
    }

    @Test func wordLeaksIntoFillerFromBefore() {
        // Word [1, 3], filler [2, 4] — trim word end to 2.
        let out = Uhm.reconcileWords([w(1, 3, "actually")], fillers: [f(2, 4)])
        #expect(out == [w(1, 2, "actually")])
    }

    @Test func wordLeaksOutOfFillerToAfter() {
        // Word [3, 5], filler [2, 4] — push word start to 4.
        let out = Uhm.reconcileWords([w(3, 5, "thinking")], fillers: [f(2, 4)])
        #expect(out == [w(4, 5, "thinking")])
    }

    @Test func wordContainsFillerEmitsLongerHalfByDefault() {
        // Word [1, 10] dur 9, filler [2, 7] dur 5 — overlap 5/9 ≈ 56% ≥ 0.5.
        // Pre=[1,2] dur 1, Post=[7,10] dur 3. Default: emit longer (post).
        let out = Uhm.reconcileWords([w(1, 10, "and-then-um-anyway")],
                                     fillers: [f(2, 7)])
        #expect(out == [w(7, 10, "and-then-um-anyway")])
    }

    @Test func wordContainsFillerSplitWhenOptedIn() {
        var opts = ReconcileOptions(); opts.splitContainedWords = true
        let out = Uhm.reconcileWords([w(1, 10, "and-um-anyway")],
                                     fillers: [f(2, 7)],
                                     options: opts)
        #expect(out == [
            w(1, 2, "and-um-anyway"),
            w(7, 10, "and-um-anyway"),
        ])
    }

    @Test func wordContainingSmallFillerSplitsRegardlessOfFraction() {
        // Word [1, 10] dur 9 fully contains filler [2, 3] dur 1 — overlap 11% < 0.5.
        // Containment is unambiguous (the word is over-extended), so it splits below
        // the fraction gate; emit the longer post half.
        let out = Uhm.reconcileWords([w(1, 10, "long")], fillers: [f(2, 3)])
        #expect(out == [w(3, 10, "long")])
    }

    @Test func shortFillerDeepInsideLongWordSplits() {
        // Production case from a transcript: 'but' [6.94, 8.70] encloses a 0.16s
        // [uh] [7.92, 8.08] — overlap only ~9%, which the fraction gate skipped,
        // leaving the filler buried in the word. Containment splits to the longer
        // pre half so the word no longer encloses the filler.
        let out = Uhm.reconcileWords([w(6.94, 8.70, "but")], fillers: [f(7.92, 8.08)])
        #expect(out == [w(6.94, 7.92, "but")])
    }

    // MARK: - minOverlapFraction gating

    @Test func tinyOverlapIgnoredAtDefaultThreshold() {
        // Word [1, 3] (dur 2), filler [2.95, 5] — overlap = 0.05s, fraction 2.5%.
        // Below 0.5 default → ignored, word passes through.
        let out = Uhm.reconcileWords([w(1, 3, "good")], fillers: [f(2.95, 5)])
        #expect(out == [w(1, 3, "good")])
    }

    @Test func tinyOverlapHonouredAtLowerThreshold() {
        var opts = ReconcileOptions(); opts.minOverlapFraction = 0.01
        let out = Uhm.reconcileWords([w(1, 3, "good")], fillers: [f(2.95, 5)], options: opts)
        // Now trims at 2.95.
        #expect(out == [w(1, 2.95, "good")])
    }

    @Test func fractionThresholdIsAgainstCurrentPieceNotOriginal() {
        // Word [0, 10] dur 10. Filler1 [2, 7] dur 5 — overlap 50%, at threshold
        // (strict <, so NOT ignored). Contains rule: pre=[0,2] dur 2,
        // post=[7,10] dur 3. Longer = post = [7, 10].
        //
        // Then filler2 [8, 10]. Piece [7, 10] dur 3. Overlap = 2.
        //   - piece-relative fraction = 2/3 ≈ 67% → ≥ 0.5, triggers.
        //   - original-word-relative fraction = 2/10 = 20% → would be ignored
        //     if (incorrectly) checked against the original word's duration.
        // So a passing result here confirms threshold is piece-relative.
        // Piece [7, 10] leaks-from-before filler [8, 10] → trim end to 8.
        let out = Uhm.reconcileWords([w(0, 10, "long")],
                                     fillers: [f(2, 7), f(8, 10)])
        #expect(out == [w(7, 8, "long")])
    }

    // MARK: - Multiple fillers per word

    @Test func multipleFillersInSingleWordWithSplit() {
        var opts = ReconcileOptions()
        opts.splitContainedWords = true
        opts.minOverlapFraction = 0.05   // small fillers, accept tiny overlaps
        // Word [0, 10], fillers at [2, 3] and [6, 7].
        // After first filler: [0,2] + [3,10] (split, both halves emitted).
        // Second filler ([6, 7]) is inside the [3, 10] piece (dur 7, overlap
        // 1, fraction ~14% ≥ 5%) → split that piece into [3,6] + [7,10].
        let out = Uhm.reconcileWords([w(0, 10, "x")],
                                     fillers: [f(2, 3), f(6, 7)],
                                     options: opts)
        #expect(out == [w(0, 2, "x"), w(3, 6, "x"), w(7, 10, "x")])
    }

    @Test func multipleFillersOnSingleWordSequentialTrim() {
        // Word [0, 6] dur 6, filler1 [0, 4] dur 4 → overlap 4/6 ≈ 67%.
        // Word starts at filler.start and ends after filler.end → leaks-to-after
        // → push start to 4. Piece = [4, 6] dur 2.
        //
        // Then filler2 [5, 7] dur 2. Piece [4, 6] vs filler [5, 7]:
        //   - overlap = 1, piece dur = 2, fraction = 50% (≥ threshold).
        //   - piece starts before filler, ends inside filler → leaks-from-before
        //     → trim end to 5. Final piece = [4, 5].
        let out = Uhm.reconcileWords([w(0, 6, "x")],
                                     fillers: [f(0, 4), f(5, 7)])
        #expect(out == [w(4, 5, "x")])
    }

    @Test func fillerSpansMultipleWords() {
        // Filler [2, 5], words [1, 3], [3, 4], [4, 6].
        //  - [1, 3] leaks-from-before → [1, 2]
        //  - [3, 4] inside filler → dropped
        //  - [4, 6] leaks-to-after → [5, 6]
        let out = Uhm.reconcileWords([
            w(1, 3, "i"),
            w(3, 4, "uhh"),
            w(4, 6, "think"),
        ], fillers: [f(2, 5)])
        #expect(out == [w(1, 2, "i"), w(5, 6, "think")])
    }

    // MARK: - Output ordering + degenerate cases

    @Test func outputIsSortedByStart() {
        // Input deliberately out of order; expect sorted output.
        let out = Uhm.reconcileWords([
            w(5, 6, "c"),
            w(1, 2, "a"),
            w(3, 4, "b"),
        ], fillers: [])
        #expect(out.map { $0.word } == ["a", "b", "c"])
    }

    @Test func zeroDurationWordsFilteredOut() {
        let out = Uhm.reconcileWords([w(2, 2, "void"), w(1, 3, "real")],
                                     fillers: [])
        #expect(out == [w(1, 3, "real")])
    }

    @Test func wordEqualToFillerIsDropped() {
        // Exact same bounds — treated as "fully inside".
        let out = Uhm.reconcileWords([w(2, 3, "uh")], fillers: [f(2, 3)])
        #expect(out == [])
    }

    // MARK: - Realistic INSIDE-class scenario from the brief

    @Test func insideClassThirtyPercentScenario() {
        // Simulates the actual production case: a transcript where some
        // words straddle, some live inside, some leak.
        let words = [
            w(0.10, 0.42, "I"),
            w(0.42, 0.81, "think"),
            w(0.81, 1.05, "um"),       // INSIDE: dropped
            w(1.05, 1.42, "that"),
            w(1.42, 1.78, "we"),
            w(1.78, 2.30, "should"),
            w(2.30, 2.65, "uh"),       // INSIDE: dropped
            w(2.65, 3.10, "definitely"),
            w(3.10, 3.55, "go"),
        ]
        let fillers = [
            f(0.78, 1.10),   // covers "um"
            f(2.28, 2.70),   // covers "uh"
        ]
        let out = Uhm.reconcileWords(words, fillers: fillers)
        #expect(out.map { $0.word } ==
                ["I", "think", "that", "we", "should", "definitely", "go"])
        // No surviving word should overlap a filler more than minOverlapFraction.
        for word in out {
            for filler in fillers {
                let lo = Swift.max(word.start, filler.start)
                let hi = Swift.min(word.end, filler.end)
                let overlap = Swift.max(0, hi - lo)
                #expect(overlap / word.duration < 0.5,
                        "word \"\(word.word)\" still overlaps filler")
            }
        }
    }
}
