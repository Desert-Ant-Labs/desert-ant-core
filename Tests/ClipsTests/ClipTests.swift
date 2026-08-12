import Foundation
import Testing
import DesertAnt
@testable import Clips

/// Selection's non-model half: the discourse features the selector is fed, the
/// candidate spans, the non-overlapping choice, and the near-duplicate cut.
///
/// These run everywhere and need no artifact, which is the point: every one of
/// them guards a constant that has to agree with training (`budget`, the
/// feature order, the span bounds) or a rule a reader notices immediately
/// (duplicates). The model-backed end-to-end suite arrives with the published
/// Hub artifacts; `HubDownloadTests` is the network-gated half that exists today.
struct ClipPipelineTests {
    /// The budget is an UPPER LIMIT set by DURATION, and it is the same rule
    /// `python/construct.py`'s `clip_budget` applies: 8 under 5 minutes, 11 to 10,
    /// 13 to 30, 14 beyond, at 2.5 words per second.
    ///
    /// This test previously asserted `n // 4` capped at 12 and called it "the same
    /// number train and eval use". It never was: the offline path capped at a literal
    /// 6, which bound on 79% of the frozen holdout. The two paths emitted different
    /// clip counts from identical input and only one of them was ever evaluated.
    @Test func budgetIsTheDurationCeilingSharedWithTrainEval() {
        // 2.5 words/sec => 150 words per minute.
        func transcript(minutes: Double) -> [String] {
            let words = Int(minutes * 60 * 2.5)
            return (0..<(words / 5)).map { _ in "one two three four five" }
        }
        #expect(Pipeline.budget(for: transcript(minutes: 1)) == 8)
        #expect(Pipeline.budget(for: transcript(minutes: 4.9)) == 8)
        #expect(Pipeline.budget(for: transcript(minutes: 7)) == 11)
        #expect(Pipeline.budget(for: transcript(minutes: 20)) == 13)
        #expect(Pipeline.budget(for: transcript(minutes: 45)) == 14)
        #expect(Pipeline.budget(for: transcript(minutes: 300)) == 14, "14 is the ceiling")
        // An empty transcript must not divide by zero or return something enormous.
        #expect(Pipeline.budget(for: []) == 8)
    }

    /// A limit SIZES the selection, it does not trim the result — and the two differ in
    /// content, not just in cost. The best set of two is not the best set of three minus one.
    @Test func aLimitSizesTheSelectionRatherThanTrimmingIt() {
        // Three disjoint spans. At budget 3 the DP takes all three; at budget 2 it takes the
        // two highest-scoring, which is NOT "the first two of the three by score" in general —
        // here it is, because they are disjoint, so the sharper check is on the BUDGET path.
        let transcript = (0..<12).map { "sentence number \($0) with distinct words \($0)" }
        let candidates = [Array(0...2), Array(4...6), Array(8...10)]
        let all = Pipeline.rank(candidates: candidates, scores: [0.2, 0.9, 0.5],
                                transcript: transcript, limit: nil)
        let two = Pipeline.rank(candidates: candidates, scores: [0.2, 0.9, 0.5],
                                transcript: transcript, limit: 2)
        #expect(all.count == 3)
        #expect(two.count == 2, "the limit bounds the emitted set")
        #expect(two.map(\.score) == [0.9, 0.5], "and it keeps the best, not the first")
        // The ceiling reaches the POOL, which is where the latency lives.
        #expect(Pipeline.budget(for: transcript, limit: 2) == 2)
        #expect(Pipeline.budget(for: transcript, limit: nil) == Pipeline.budget(for: transcript))
        #expect(Pipeline.budget(for: transcript, limit: 0) == 1, "a zero limit is floored at 1")
    }

    /// Weighted interval scheduling takes the best-scoring compatible set, not
    /// the greedy claim order: two good spans beat one better one.
    @Test func selectionPrefersTheBestCompatibleSet() {
        let chosen = Pipeline.selectNonOverlapping(
            [(0, 9, 10.0), (0, 3, 6.0), (5, 9, 6.0)], budget: 4)
        #expect(chosen.map { [$0.0, $0.1] } == [[0, 3], [5, 9]])
    }

    @Test func selectionNeverOverlaps() {
        let spans: [(Int, Int, Double)] = [(0, 4, 5), (3, 7, 9), (6, 10, 4), (8, 12, 7)]
        let chosen = Pipeline.selectNonOverlapping(spans, budget: 3).sorted { $0.0 < $1.0 }
        for (a, b) in zip(chosen, chosen.dropFirst()) {
            #expect(a.1 < b.0, "spans \(a) and \(b) overlap")
        }
    }

    @Test func selectionRespectsTheBudget() {
        let spans = (0..<20).map { (i: Int) in (i * 2, i * 2 + 1, Double(i)) }
        #expect(Pipeline.selectNonOverlapping(spans, budget: 3).count == 3)
        #expect(Pipeline.selectNonOverlapping(spans, budget: 0).isEmpty)
    }

    /// Readers punish duplicates hard, so a span repeating a kept one goes.
    @Test func dedupeDropsNearDuplicates() {
        let transcript = ["alpha beta gamma", "delta epsilon zeta", "eta theta iota"]
        let kept = Pipeline.dedupe([(0, 1, 9.0), (0, 1, 8.0), (2, 2, 7.0)], transcript: transcript)
        #expect(kept.count == 2)
        #expect(kept.map(\.2) == [9.0, 7.0], "the first (higher) of a duplicate pair is kept")
    }

    @Test func dedupeKeepsDistinctMoments() {
        let transcript = ["alpha beta", "gamma delta", "epsilon zeta", "eta theta"]
        let kept = Pipeline.dedupe([(0, 1, 9.0), (2, 3, 8.0)], transcript: transcript)
        #expect(kept.count == 2)
    }

    /// Candidates stay inside the trained span length and the anchor window.
    @Test func candidatesRespectTheSpanBounds() {
        let saliency = (0..<40).map { Double(40 - $0) }
        let candidates = Pipeline.enumerateCandidates(count: 40, saliency: saliency, budget: 10)
        #expect(!candidates.isEmpty)
        for span in candidates {
            #expect(span.count >= Pipeline.minSentences && span.count <= Pipeline.maxSentences)
            #expect(span == Array(span.first!...span.last!), "candidates are contiguous runs")
            #expect(span.first! >= 0 && span.last! < 40)
        }
        #expect(Set(candidates).count == candidates.count, "candidates are deduplicated")
    }

    @Test func candidatesAreEmptyForATranscriptShorterThanASpan() {
        #expect(Pipeline.enumerateCandidates(count: 2, saliency: [1, 0], budget: 8).isEmpty)
    }

    /// The 5 scalars the heads were trained with, in order:
    /// [position, hookCount, payoffCount, endsWithQuestion, digitRatio].
    /// Position FIRST, and the middle two are COUNTS of matching patterns, not
    /// booleans - an earlier hand-written version had all five wrong.
    @Test func discourseFeaturesAreOrderedAsInTraining() {
        let plain = Pipeline.discourseFeatures("the cat sat on the mat", position: 0.25)
        #expect(plain.count == 5)
        #expect(plain[0] == 0.25, "position comes first")
        #expect(plain[1] == 0 && plain[2] == 0)
        #expect(plain[3] == 0)
        #expect(plain[4] == 0)
    }

    @Test func discourseFeaturesCountPatternsRatherThanFlagThem() {
        // "Here's why nobody ever..." matches \bhere'?s\b, \bwhy\b, nobody, and
        // \b(never|always|everyone|no one|nobody)\b: four hook patterns, so the
        // feature is 4 and not 1.
        let many = Pipeline.discourseFeatures("Here's why nobody ever wins", position: 0)
        #expect(many[1] == 4, "hook features are a count of matching patterns, got \(many[1])")
    }

    @Test func discourseFeaturesDetectQuestionsAndDigits() {
        let question = Pipeline.discourseFeatures("what if it is true?  ", position: 0)
        #expect(question[3] == 1, "trailing whitespace must not hide the question mark")
        let digits = Pipeline.discourseFeatures("1234", position: 0)
        #expect(abs(digits[4] - 4.0 / 5.0) < 1e-6, "digits over character count plus one")
    }

    @Test func rankingIsBestFirstWithPercentileSpanningTheList() {
        let transcript = (0..<12).map { "sentence number \($0) with distinct words \($0)" }
        let candidates = [Array(0...2), Array(4...6), Array(8...10)]
        let moments = Pipeline.rank(
            candidates: candidates, scores: [0.2, 0.9, 0.5], transcript: transcript, limit: nil)
        #expect(moments.map(\.score) == [0.9, 0.5, 0.2], "best first")
        #expect(moments.map(\.id) == [0, 1, 2])
        #expect(moments.first?.percentile == 1.0)
        #expect(moments.last?.percentile == 0.0)
        #expect(moments.allSatisfy { (0...1).contains($0.percentile) })
        #expect(moments.first?.sentenceIDs == [4, 5, 6])
        #expect(moments.first?.text == candidates[1].map { transcript[$0] }.joined(separator: " "))
    }

    @Test func aSingleMomentIsTheTopPercentile() {
        let transcript = (0..<6).map { "word\($0) alpha\($0) beta\($0)" }
        let moments = Pipeline.rank(
            candidates: [Array(0...2)], scores: [0.4], transcript: transcript, limit: nil)
        #expect(moments.count == 1)
        #expect(moments[0].percentile == 1.0, "one moment must not divide by zero")
    }
}

/// The tokenizer's truncation contract, over a synthetic vocab so it needs no
/// download. This is the invariant that cost real quality: HuggingFace's
/// `truncation=True, max_length=` KEEPS the eos, and a plain `prefix(maxLength)`
/// silently replaces it with one more content token, so every span longer than
/// the bucket is scored on input the model never saw in training.
struct ClipTokenizerTests {
    @Test func truncationKeepsTheEndOfSequenceToken() throws {
        let tokenizer = try #require(Tokenizer(bytes: syntheticVocab()))
        let long = String(repeating: "a b c ", count: 20)
        let ids = tokenizer.encode(long, maxLength: 8)
        #expect(ids.count == 8)
        #expect(ids.first == Int32(tokenizer.bosID))
        #expect(ids.last == Int32(tokenizer.eosID), "truncation must keep </s>, not drop it")
    }

    @Test func shortInputIsNotTruncated() throws {
        let tokenizer = try #require(Tokenizer(bytes: syntheticVocab()))
        let ids = tokenizer.encode("a b", maxLength: 128)
        #expect(ids.first == Int32(tokenizer.bosID))
        #expect(ids.last == Int32(tokenizer.eosID))
        #expect(ids.count == 4, "<s> ▁a ▁b </s>")
    }

    @Test func aMalformedVocabIsRejectedRatherThanGuessed() {
        #expect(Tokenizer(bytes: [0x00, 0x01, 0x02, 0x03, 0x04]) == nil)
        #expect(Tokenizer(bytes: Array(syntheticVocab().dropLast(4))) == nil)
    }

    /// Two vocab pieces that are byte-distinct but *canonically equivalent* must
    /// stay two pieces. Swift's `String` equality is canonical equivalence, so a
    /// `[String: Int]` vocab merges them into one key and the later id evicts the
    /// earlier - after which nothing can ever produce it, and the loader's own
    /// "every piece landed in the index" check fails, which is why a `String`-keyed
    /// index cannot load the real 250,002-piece vocab at all.
    @Test func canonicallyEquivalentPiecesStayDistinct() throws {
        // ▁ + Kannada VOWEL SIGN OO, then ▁ + the VOWEL SIGN O and LENGTH MARK it
        // decomposes to. The same pair, in the same order, as ids 9440 and 80321
        // in xlm-roberta-base.
        let precomposed = "\u{2581}\u{0CCB}"
        let decomposed = "\u{2581}\u{0CCA}\u{0CD5}"
        #expect(precomposed == decomposed, "the premise: Swift calls these equal")
        #expect(Array(precomposed.utf8) != Array(decomposed.utf8), "but they are not the same bytes")

        let vocab = vocabBytes(
            pieces: ["<s>", "<pad>", "</s>", "<unk>", precomposed, decomposed],
            scores: [0, 0, 0, 0, -1, -1])
        let tokenizer = try #require(Tokenizer(bytes: vocab), "a colliding vocab must still load")
        // The reachable piece is the earlier id, so `String` keying evicts exactly
        // the one the input needs and this comes back as `<unk>`.
        #expect(tokenizer.encode("\u{0CCB}", maxLength: 128) == [0, 4, 2])
    }

}

/// A minimal vocab in the compact container `Tokenizer` reads: `<s>`, `<pad>`,
/// `</s>`, `<unk>` at the xlm-roberta ids, then `▁a`, `▁b`, `▁c`.
func syntheticVocab() -> [UInt8] {
    vocabBytes(
        pieces: ["<s>", "<pad>", "</s>", "<unk>", "\u{2581}a", "\u{2581}b", "\u{2581}c"],
        scores: [0, 0, 0, 0, -1, -1, -1])
}

/// The compact container, written the way `build_tokenizer_bin.py` writes it, so
/// a test can state a vocab as pieces rather than as a byte literal. `<unk>`,
/// `<s>` and `</s>` are at the xlm-roberta ids 3, 0 and 2.
func vocabBytes(pieces: [String], scores: [Float]) -> [UInt8] {
    var bytes: [UInt8] = [0x52, 0x44, 0x54, 0x4B, 0x01]  // "RDTK" + version
    func int32(_ value: Int) {
        let bits = UInt32(bitPattern: Int32(value))
        bytes.append(contentsOf: (0..<4).map { UInt8((bits >> (8 * $0)) & 0xFF) })
    }
    int32(3)  // unk
    int32(0)  // bos
    int32(2)  // eos
    int32(pieces.count)
    for score in scores {
        let bits = score.bitPattern
        bytes.append(contentsOf: (0..<4).map { UInt8((bits >> (8 * $0)) & 0xFF) })
    }
    for piece in pieces {
        let length = Array(piece.utf8).count
        bytes.append(UInt8(length & 0xFF))
        bytes.append(UInt8((length >> 8) & 0xFF))
    }
    for piece in pieces { bytes.append(contentsOf: Array(piece.utf8)) }
    return bytes
}

/// The catalog declaration, which is the model's whole contract with tooling.
struct ClipCatalogTests {
    /// Selection runs two graphs, and both must be in the platform manifest -
    /// the shared `manifestsContainTheirArtifact` only proves the first.
    @Test func everyPlatformShipsBothHalvesAndTheTokenizer() {
        for (platform, files) in ClipModel.files {
            let selector = ClipModel.selector(for: platform)
            let scorer = ClipModel.scorer(for: platform)
            #expect(selector != scorer,
                    "\(platform.rawValue): the two halves must be addressable apart")
            for export in [selector, scorer] {
                #expect(files.contains(export.file) || files.contains(export.file + "/"),
                        "\(platform.rawValue): manifest is missing \(export.file)")
            }
            #expect(files.contains(ClipModel.tokenizer),
                    "\(platform.rawValue): manifest is missing the tokenizer")
        }
    }

    /// Apple ships ONE asset carrying both graphs over the encoder they share -
    /// 281 MB rather than the 535 MB two packages cost - so there the file name
    /// cannot tell the halves apart and the function name is what does. A path
    /// with no function is not a model: Core ML loads the package's default and
    /// says nothing, which would run the selector for both halves.
    ///
    /// LiteRT has no multifunction packaging, so everywhere else the halves are
    /// two files and name no function.
    @Test func appleAddressesOneAssetByFunctionAndEveryoneElseByFile() {
        let selector = ClipModel.selector(for: .apple)
        let scorer = ClipModel.scorer(for: .apple)
        #expect(selector.file == ClipModel.coreML && scorer.file == ClipModel.coreML)
        #expect(selector.function == "select" && scorer.function == "score")
        #expect(ClipModel.artifact(for: .apple) == ClipModel.coreML)
        #expect(ClipModel.files[.apple] == [ClipModel.coreML + "/", ClipModel.tokenizer])

        for platform in [ModelPlatform.linux, .android, .windows] {
            let selector = ClipModel.selector(for: platform)
            let scorer = ClipModel.scorer(for: platform)
            #expect(selector.file != scorer.file, "\(platform.rawValue): two files, not one")
            #expect(selector.function == nil && scorer.function == nil,
                    "\(platform.rawValue): LiteRT has no function to name")
        }
    }

    /// No `.web` manifest: the wasm host holds one compiled model per module and
    /// selection needs two sessions. Declaring web files would resolve artifacts
    /// the browser could not both compile.
    @Test func webIsNotClaimed() {
        #expect(!ClipModel.supports(.web))
        #expect(ClipModel.supports(.apple) && ClipModel.supports(.linux) && ClipModel.supports(.android))
    }
}
