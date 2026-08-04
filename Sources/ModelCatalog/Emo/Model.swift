import DesertAnt

/// The neural stage: tokenize a phrase into the model's fixed-window feature
/// tensors, run them through the shared `InferenceSession` (Core ML | LiteRT | JS
/// host, chosen by desert-ant-core), and read the emoji probability vector. This
/// file only knows emo's tensor layout; the runtime is oblivious.
final class Model: @unchecked Sendable {
    private let session: any InferenceSession
    private let meta: EmoMeta
    private let sem: SemTokenizer

    init(assets: ModelAssets) throws {
        session = assets.session
        meta = try EmoMeta(json: assets.metaJSON)
        guard let sem = SemTokenizer(bytes: assets.tokenizer) else {
            throw EmoError.modelNotFound
        }
        self.sem = sem
    }

    /// Suggest emojis for a phrase, most likely first. Empty input returns `[]`.
    func suggestions(for text: String, limit: Int, skinTone: EmojiSkinTone) async throws -> [EmoSuggestion] {
        let probs = try await probabilities(text)
        let labels = meta.labels
        var scored: [(String, Double)] = []
        scored.reserveCapacity(min(labels.count, probs.count))
        for i in 0..<min(labels.count, probs.count) { scored.append((labels[i], Double(probs[i]))) }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(max(0, limit))
            .map { EmoSuggestion(emoji: $0.0.applyingSkinTone(skinTone), confidence: $0.1) }
    }

    // MARK: inference

    /// Build the fixed-window tensors (n-gram stream + masked semantic sequence)
    /// and read the `probabilities` output. Both the Core ML and LiteRT exports
    /// share this exact signature, so there is nothing platform-specific here.
    private func probabilities(_ text: String) async throws -> [Float] {
        let fmax = meta.fmax
        let smax = meta.smax
        let kh = meta.nHashes

        let (buckets, signs, importance) = NGram.encode(
            text, nBuckets: UInt32(meta.nBuckets), nHashes: kh,
            nImportance: UInt32(meta.nImportance), maxFeatures: fmax)
        let nf = min(buckets.count, fmax)

        var ngBuckets = [Int32](repeating: 0, count: fmax * kh)
        var ngSigns = [Float](repeating: 0, count: fmax * kh)
        var ngImportance = [Int32](repeating: 0, count: fmax)
        for f in 0..<nf {
            ngImportance[f] = importance[f]
            for k in 0..<kh {
                ngBuckets[f * kh + k] = buckets[f][k]
                ngSigns[f * kh + k] = signs[f][k]
            }
        }

        var ids = sem.encode(text)
        if ids.count > smax { ids = Array(ids.prefix(smax)) }
        var semIDs = [Int32](repeating: Int32(meta.semPadIndex), count: smax)
        var semMask = [Float](repeating: 0, count: smax)
        if ids.isEmpty {
            // Match the export: no real tokens -> one padded (zero-embedding)
            // position kept unmasked, so the pool never sees an all-masked row.
            semMask[0] = 1
        } else {
            for s in ids.indices { semIDs[s] = ids[s]; semMask[s] = 1 }
        }

        let output = try await session.run(
            inputs: [
                "ngram_buckets": Tensor(int32: ngBuckets, shape: [1, fmax, kh]),
                "ngram_signs": Tensor(float32: ngSigns, shape: [1, fmax, kh]),
                "ngram_importance": Tensor(int32: ngImportance, shape: [1, fmax]),
                "ngram_count": Tensor(float32: [Float(max(nf, 1))], shape: [1, 1]),
                "sem_ids": Tensor(int32: semIDs, shape: [1, smax]),
                "sem_mask": Tensor(float32: semMask, shape: [1, smax]),
            ],
            outputs: ["probabilities"])[0]
        guard let probs = output.float32Values, !probs.isEmpty else {
            throw EmoError.predictionFailed
        }
        return probs
    }
}
