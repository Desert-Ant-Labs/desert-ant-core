import DesertAnt

// Semantic stream: the vocab-pruned potion static embedding. Tokenize (Unigram),
// gather the int8 rows, dequantize, mean-pool, L2-normalize. Matches the Python
// model2vec `encode` for the pruned model (normalize: true).

struct EmbeddingMeta: Decodable {
    let vocab_size: Int
    let dim: Int
    let scale: Float
    let normalize: Bool
}

struct Embedding {
    let dim: Int
    private let rows: [Int8]
    private let scale: Float
    private let normalize: Bool

    init(rows: [Int8], meta: EmbeddingMeta) {
        self.rows = rows
        self.dim = meta.dim
        self.scale = meta.scale
        self.normalize = meta.normalize
    }

    init(rows: [UInt8], metaJSON: String) throws {
        let meta = try JSONDecoder().decode(EmbeddingMeta.self, from: metaJSON)
        self.init(rows: rows.map { Int8(bitPattern: $0) }, meta: meta)
    }

    /// Mean-pool the token rows (dequantized), then L2-normalize.
    func pool(ids: [Int]) -> [Float] {
        var out = [Float](repeating: 0, count: dim)
        var n = 0
        for id in ids where id >= 0 && (id + 1) * dim <= rows.count {
            let base = id * dim
            for j in 0..<dim { out[j] += Float(rows[base + j]) * scale }
            n += 1
        }
        if n > 0 { for j in 0..<dim { out[j] /= Float(n) } }
        if normalize {
            var norm: Float = 0
            for x in out { norm += x * x }
            norm = norm.squareRoot()
            if norm > 0 { for j in 0..<dim { out[j] /= norm } }
        }
        return out
    }
}
