import DesertAnt
import Transcript

/// The neural stage: tokenize sentences and spans into the exports' fixed
/// batch-16 x 128-token buckets, run them through the shared
/// `InferenceSession` (Core ML | LiteRT, chosen by desert-ant-core), and read
/// the per-sentence signals and per-span scores. This file only knows clip's
/// tensor layout; the runtime is oblivious. Choosing which spans to keep is
/// `Pipeline.swift`.
///
/// The exported signatures:
///
///     selector: ids[16,128] int32, mask[16,128] int32, disc[16,5] float32
///               -> saliency[16], start_p[16], end_p[16]
///     scorer:   ids[16,128] int32, mask[16,128] int32 -> score[16]
///
/// The two functions CAN run at different sequence lengths — the package format
/// supports it and the exporters build it — but the shipping artifact runs both
/// at 128. See ``Model/scoreSeqLen`` for why that is not the window the scorer
/// trained at, and what it would cost to change.
///
/// Fixed shapes throughout: sessions cache their input buffers per shape and
/// rebuild whenever one changes, so feeding arbitrary lengths would trade
/// padding waste for buffer churn. Two fixed shapes, one per function, keeps
/// that property - each session still sees exactly one shape for its lifetime.
final class Model: @unchecked Sendable {
    /// Batch 16 is optimal and throughput DEGRADES above it: 2.92 ms/candidate
    /// at 16, 3.18 at 32, 3.73 at 64. Opposite to GPU intuition; do not raise it.
    static let batch = 16

    /// The SELECTOR graph's buffer width. A property of the compiled artifact, and NOT the
    /// point at which a sentence is truncated — see ``sentenceTokens``.
    static let seqLen = 128

    /// Where a SENTENCE is cut for the selector, and the window its heads were TRAINED at.
    ///
    /// Not `seqLen`. `train_selector.py:195` pools sentence embeddings at `heads.MAXTOK` = 64,
    /// `train_spans.py:70` tokenizes at the same constant, and every checkpoint's
    /// `run_manifest.json` records `"sentence_window": 64` as a first-class config field. The
    /// saliency, start and end heads have never seen a sentence pooled over more than 64
    /// tokens.
    ///
    /// This was `seqLen`, i.e. 128, because one constant served as both the buffer width and
    /// the truncation point. That ran the heads off-distribution on 3.47% of sentences and
    /// **76% of the frozen holdout's videos**, and changed the emitted clip set on 30% of a
    /// 20-video quantile sample (micro-IoU 0.901 against the trained path).
    ///
    /// It needs no re-export: masked-mean pooling plus the additive attention mask means a
    /// 128-wide buffer fed a mask zeroed past token 64 is bit-identical to a 64-wide graph.
    static let sentenceTokens = 64

    /// Fallback SCORER window, used only when a runtime cannot report its own shape.
    ///
    /// The real width is read from the loaded graph — see ``scoreWidth`` — because it is the
    /// axis the model arms vary and the two candidate packages differ in exactly this number:
    /// the 128 package serves `score` at [16,128] and the 256 package at [16,256], identical
    /// in every other respect of their I/O. Hardcoding it truncates every candidate to 128 on
    /// a 256 artifact and returns a null by construction, which is what `bench_latency.py` was
    /// retired for.
    ///
    /// A 256 build was promoted and unwound on 2026-08-10 for want of evidence. That evidence
    /// now exists and is in `docs/export.md`: measured end to end on real transcripts rather
    /// than extrapolated from a scorer multiplier, 256 costs +75% to +134% and buys +0.068
    /// Likert, which the product owner has accepted.
    static let scoreSeqLen = 128

    private let selector: any InferenceSession
    private let scorer: any InferenceSession
    private let tokenizer: Tokenizer

    /// Buffer widths taken from the LOADED GRAPHS, falling back to the constants above only
    /// when a runtime cannot report shapes. This is what lets one binary serve the 128 package
    /// and the 256 package without a rebuild, and what stops a 256 artifact being silently
    /// truncated to 128 — which would make a window comparison return no difference by
    /// construction.
    private var selectWidth: Int { selector.inputWidth("ids") ?? Self.seqLen }
    private var scoreWidth: Int { scorer.inputWidth("ids") ?? Self.scoreSeqLen }

    init(assets: ModelAssets) throws {
        selector = assets.selector
        scorer = assets.scorer
        guard let tokenizer = Tokenizer(bytes: assets.tokenizer) else {
            throw ClipError.modelNotFound
        }
        self.tokenizer = tokenizer
    }

    /// The whole pipeline: per-sentence signals, candidate spans, span scores,
    /// then the non-overlapping choice. See `Pipeline.swift` for the selection.
    func clips(in transcript: [String], limit: Int?) async throws -> [Clip] {
        guard transcript.count >= Pipeline.minSentences else { return [] }
        let saliency = try await perSentenceSaliency(transcript)
        // Computed once and threaded through: the anchor count is `budget * 4`, so enumeration
        // and ranking must size from one number or the pool is not the one the ranker expects.
        // This is also where a caller's limit earns its latency: a smaller ceiling means a
        // smaller pool and fewer scorer passes, which is most of the runtime.
        let candidates = Pipeline.enumerateCandidates(
            count: transcript.count, saliency: saliency,
            budget: Pipeline.budget(for: transcript, limit: limit))
        guard !candidates.isEmpty else { return [] }
        let texts = candidates.map { span in span.map { transcript[$0] }.joined(separator: " ") }
        let scores = try await scoreSpans(texts)
        return Pipeline.rank(candidates: candidates, scores: scores, transcript: transcript,
                             limit: limit)
    }

    // MARK: inference

    /// Per-sentence saliency, batched. `start_p`/`end_p` are read off the same
    /// pass because the export emits all three, but only saliency picks anchors
    /// today - the span boundaries come from the scorer's ranking instead.
    private func perSentenceSaliency(_ sentences: [String]) async throws -> [Double] {
        var saliency: [Double] = []
        saliency.reserveCapacity(sentences.count)
        let n = sentences.count
        for start in stride(from: 0, to: n, by: Self.batch) {
            let slice = sentences[start..<min(start + Self.batch, n)]
            var ids = [Int32](repeating: 0, count: Self.batch * selectWidth)
            var mask = [Int32](repeating: 0, count: Self.batch * selectWidth)
            var disc = [Float](repeating: 0, count: Self.batch * 5)
            for (r, sentence) in slice.enumerated() {
                write(sentence, row: r, ids: &ids, mask: &mask, width: selectWidth,
                      truncateAt: Self.sentenceTokens)
                // The 5 discourse scalars the heads were trained with. Passed in
                // rather than derived in-graph: deriving from shapes is what
                // emits aten::Int and breaks conversion.
                let features = Pipeline.discourseFeatures(
                    sentence, position: Double(start + r) / Double(max(n, 1)))
                for (c, value) in features.enumerated() { disc[r * 5 + c] = value }
            }
            let out = try await selector.run(
                inputs: ["ids": Tensor(int32: ids, shape: [Self.batch, selectWidth]),
                         "mask": Tensor(int32: mask, shape: [Self.batch, selectWidth]),
                         "disc": Tensor(float32: disc, shape: [Self.batch, 5])],
                outputs: ["saliency", "start_p", "end_p"])
            guard out.count == 3, let values = out[0].float32Values, values.count >= slice.count else {
                throw ClipError.predictionFailed
            }
            for r in 0..<slice.count { saliency.append(Double(values[r])) }
        }
        return saliency
    }

    /// Per-span quality, batched.
    private func scoreSpans(_ texts: [String]) async throws -> [Double] {
        var scores: [Double] = []
        scores.reserveCapacity(texts.count)
        for start in stride(from: 0, to: texts.count, by: Self.batch) {
            let slice = texts[start..<min(start + Self.batch, texts.count)]
            var ids = [Int32](repeating: 0, count: Self.batch * scoreWidth)
            var mask = [Int32](repeating: 0, count: Self.batch * scoreWidth)
            for (r, text) in slice.enumerated() {
                write(text, row: r, ids: &ids, mask: &mask, width: scoreWidth)
            }
            let out = try await scorer.run(
                inputs: ["ids": Tensor(int32: ids, shape: [Self.batch, scoreWidth]),
                         "mask": Tensor(int32: mask, shape: [Self.batch, scoreWidth])],
                outputs: ["score"])
            guard let values = out.first?.float32Values, values.count >= slice.count else {
                throw ClipError.predictionFailed
            }
            for r in 0..<slice.count { scores.append(Double(values[r])) }
        }
        return scores
    }

    /// Tokenize `text` into row `r` of a batch `width` tokens wide, setting the
    /// attention mask for exactly the tokens written. Rows past the end of a short
    /// final batch stay all-zero, and are dropped by the caller rather than read
    /// back.
    ///
    /// `width` is the buffer STRIDE and is a parameter rather than a constant because the two
    /// graphs run at different lengths. Truncating to one width and indexing with another
    /// silently interleaves rows - every row after the first lands at the wrong offset, the
    /// mask stops matching the ids, and the model returns finite numbers for a scrambled batch.
    ///
    /// `truncateAt` is where the TEXT is cut, and it defaults to the stride because for the
    /// scorer the two are the same number. For the selector they are not: the buffer is the
    /// graph's 128 and the cut is the heads' trained 64. Keeping them as one parameter is what
    /// ran the selector off-distribution on 76% of holdout videos, so they are two parameters
    /// now and the caller states both.
    private func write(_ text: String, row r: Int, ids: inout [Int32], mask: inout [Int32],
                       width: Int = Model.seqLen, truncateAt: Int? = nil) {
        let cut = min(truncateAt ?? width, width)
        for (c, token) in tokenizer.encode(text, maxLength: cut).enumerated() where c < cut {
            ids[r * width + c] = token
            mask[r * width + c] = 1
        }
    }
}
