import DesertAnt

/// Runs the two-stream pipeline: tokenize -> semantic pool + hashed n-grams ->
/// concat -> the MLP head through the shared `InferenceSession` (LiteRT / Core ML
/// / JS host) -> per-topic probabilities. The head is the only part that touches
/// the model artifact; everything else is pure Swift.
final class Model: @unchecked Sendable {
    let slugs: [String]
    let names: [String: String]
    let threshold: Double

    private let tokenizer: Tokenizer
    private let embedding: Embedding
    private let session: any InferenceSession
    private let ngramDim: Int

    struct Config: Decodable { let slugs: [String]; let ngram_dim: Int; let threshold: Double }

    init(assets: ModelAssets) throws {
        guard let tok = Tokenizer(bytes: assets.tokenizer) else { throw GistError.modelNotFound }
        tokenizer = tok
        embedding = try Embedding(rows: assets.embedding, metaJSON: assets.embeddingMetaJSON)
        let cfg = try JSONDecoder().decode(Config.self, from: assets.configJSON)
        slugs = cfg.slugs
        ngramDim = cfg.ngram_dim
        threshold = cfg.threshold
        names = try Model.parseNames(assets.taxonomyJSON)
        session = assets.session
    }

    private struct Taxonomy: Decodable {
        struct Topic: Decodable { let slug: String; let name: String }
        let topics: [Topic]
    }
    private static func parseNames(_ json: String) throws -> [String: String] {
        let tax = try JSONDecoder().decode(Taxonomy.self, from: json)
        return Dictionary(uniqueKeysWithValues: tax.topics.map { ($0.slug, $0.name) })
    }

    /// Full 36-topic probability distribution for `text`.
    func scores(_ text: String) async throws -> [String: Double] {
        let ids = tokenizer.encode(text)
        var feats = embedding.pool(ids: ids)
        feats.append(contentsOf: NGrams.features(text, dim: ngramDim))

        let out = try await session.run(
            inputs: ["features": Tensor(float32: feats, shape: [1, feats.count])],
            outputs: ["topic_probs"])[0]
        guard let probs = out.float32Values, probs.count >= slugs.count else {
            throw GistError.predictionFailed
        }
        var result: [String: Double] = [:]
        for (i, slug) in slugs.enumerated() { result[slug] = Double(probs[i]) }
        return result
    }
}
