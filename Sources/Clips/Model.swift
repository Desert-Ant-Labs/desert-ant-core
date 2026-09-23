import DesertAnt
import Transcript

/// The neural stage: tokenize sentences and spans into the exports' fixed
/// batch-16 buckets and read the per-sentence signals and per-span scores.
/// Choosing which spans to keep is `Pipeline.swift`.
///
/// The exported signatures:
///
///     selector: ids[16,128] int32, mask[16,128] int32, disc[16,5] float32
///               -> saliency[16], start_p[16], end_p[16]
///     scorer:   ids[16,128] int32, mask[16,128] int32 -> score[16]
///
/// The signatures above are the 128 package's. The two functions can run at
/// different sequence lengths, so widths are read from the loaded graph (see
/// ``Model/scoreSeqLen``).
///
/// Fixed shapes throughout: sessions cache their input buffers per shape and
/// rebuild whenever one changes, so feeding arbitrary lengths would trade
/// padding waste for buffer churn. Each session sees exactly one shape.
final class Model: @unchecked Sendable {
    /// Batch 16 is optimal and throughput degrades above it: 2.92 ms/candidate
    /// at 16, 3.18 at 32, 3.73 at 64. Opposite to GPU intuition; do not raise it.
    static let batch = 16

    /// Fallback selector buffer width. A property of the compiled artifact, not the point
    /// at which a sentence is truncated (see ``sentenceTokens``).
    static let seqLen = 128

    /// Where a sentence is cut for the selector: the window its heads were trained at.
    ///
    /// Not `seqLen`. `train_selector.py:195` pools sentence embeddings at `heads.MAXTOK` = 64,
    /// `train_spans.py:70` tokenizes at the same constant, and every checkpoint's
    /// `run_manifest.json` records `"sentence_window": 64`. Cutting at 128 runs the heads
    /// off-distribution on 3.47% of sentences and 76% of the frozen holdout's videos, and
    /// changes the emitted clip set on 30% of a 20-video quantile sample (micro-IoU 0.901).
    ///
    /// Masked-mean pooling plus the additive attention mask make a 128-wide buffer fed a
    /// mask zeroed past token 64 bit-identical to a 64-wide graph, so no re-export is needed.
    static let sentenceTokens = 64

    /// Fallback scorer window, used only when a runtime cannot report its own shape.
    ///
    /// The real width is read from the loaded graph (``scoreWidth``) because it is the axis
    /// the model arms vary: the 128 package serves `score` at [16,128] and the 256 package at
    /// [16,256], identical otherwise. Hardcoding it would truncate every candidate to 128 on a
    /// 256 artifact. `docs/export.md` has the end-to-end cost of 256: +75% to +134% for
    /// +0.068 Likert.
    static let scoreSeqLen = 128

    private let selector: any InferenceSession
    private let scorer: any InferenceSession
    private let tokenizer: Tokenizer

    /// Buffer widths taken from the loaded graphs, so one binary serves the 128 and 256
    /// packages without a rebuild and a 256 artifact is never silently truncated to 128.
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
        let candidates = Pipeline.enumerateCandidates(
            count: transcript.count, saliency: saliency,
            budget: Pipeline.budget(for: transcript, limit: limit))
        guard !candidates.isEmpty else { return [] }
        let texts = candidates.map { span in span.map { transcript[$0] }.joined(separator: " ") }
        let scores = try await scoreSpans(texts)
        return Pipeline.rank(candidates: candidates, scores: scores, transcript: transcript,
                             limit: limit)
    }

    /// Per-sentence saliency, batched. The export also emits `start_p`/`end_p`,
    /// but only saliency picks anchors; span boundaries come from the scorer's ranking.
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
    /// `width` is the buffer stride. Truncating to one width and indexing with another
    /// silently interleaves rows: every row after the first lands at the wrong offset, the
    /// mask stops matching the ids, and the model returns finite numbers for a scrambled batch.
    ///
    /// `truncateAt` is where the text is cut. It defaults to the stride, which is right for the
    /// scorer; the selector's buffer is 128 but its cut is the heads' trained 64
    /// (``sentenceTokens``).
    private func write(_ text: String, row r: Int, ids: inout [Int32], mask: inout [Int32],
                       width: Int = Model.seqLen, truncateAt: Int? = nil) {
        let cut = min(truncateAt ?? width, width)
        for (c, token) in tokenizer.encode(text, maxLength: cut).enumerated() where c < cut {
            ids[r * width + c] = token
            mask[r * width + c] = 1
        }
    }
}
