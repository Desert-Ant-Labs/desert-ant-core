import Foundation

/// Minimal dense linear layer.
struct Linear: Sendable {
    let outFeatures: Int
    let inFeatures: Int
    let weight: [Float]   // row-major [out, in]
    let bias: [Float]

    // No `apply` on a single row: every use goes through `Matmul.linear` over the whole
    // sequence at once, which is the entire point of the Accelerate path. A row-at-a-time
    // helper would be an inviting way to reintroduce the scalar cost this replaced.
}

struct LayerNorm: Sendable {
    let weight: [Float]
    let bias: [Float]
    /// Matches PyTorch's default and `chapters_model.py`'s `nn.LayerNorm`.
    let eps: Float = 1e-5

    // Applied over a whole sequence by `Matmul.layerNormRows`.
}

enum ChapterWeightsError: Error, CustomStringConvertible {
    case badMagic
    case unsupportedFormat(String)
    case truncated(expected: Int, got: Int)
    case shapeMismatch(String)

    var description: String {
        switch self {
        case .badMagic: return "not a chapters weight file (bad magic)"
        case .unsupportedFormat(let f): return "unsupported chapters format \(f)"
        case .truncated(let e, let g): return "chapters file truncated: expected \(e) floats, got \(g)"
        case .shapeMismatch(let m): return "chapters weight shape mismatch: \(m)"
        }
    }
}

extension ChapterWeights {
    /// Load the flat format `python/export_chapters.py` writes.
    ///
    /// Validates every shape against the header rather than trusting byte offsets, because the
    /// failure mode of a silently misread offset is a model that runs and is wrong, which is
    /// far more expensive than a load error.
    static func load(contentsOf url: URL) throws -> ChapterWeights {
        try load(data: try Data(contentsOf: url))
    }

    /// Load from bytes already in memory, which is how `ModelAssets` hands it over: the
    /// resolved model may live somewhere `StoredModel` reads for us rather than at a URL we
    /// can open.
    static func load(bytes: [UInt8]) throws -> ChapterWeights {
        try load(data: Data(bytes))
    }

    static func load(data: Data) throws -> ChapterWeights {
        guard data.count > 8, data.prefix(4) == Data("DACH".utf8) else {
            throw ChapterWeightsError.badMagic
        }
        let headerLength = Int(data[4..<8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        let headerEnd = 8 + headerLength
        guard data.count >= headerEnd else { throw ChapterWeightsError.badMagic }
        let header = try JSONSerialization.jsonObject(
            with: data[8..<headerEnd]) as? [String: Any] ?? [:]
        guard header["format"] as? String == "desert-ant-chapters-v1" else {
            throw ChapterWeightsError.unsupportedFormat(
                header["format"] as? String ?? "unknown")
        }

        let dim = header["dim"] as? Int ?? 256
        let layerCount = header["layers"] as? Int ?? 2
        let heads = header["heads"] as? Int ?? 4
        // Read from the header, not hardcoded: the parity fixture uses a small
        // feed-forward so it can be committed, and a loader that assumed 1024
        // would reject the very file that proves it correct.
        let ff = header["ff"] as? Int ?? 1024
        let entries = header["tensors"] as? [[String: Any]] ?? []

        var floats: [Float] = []
        data[headerEnd...].withUnsafeBytes { raw in
            floats = Array(raw.bindMemory(to: Float.self))
        }
        var cursor = 0
        func next(_ name: String, _ expected: [Int]) throws -> [Float] {
            guard cursor < entries.count else {
                throw ChapterWeightsError.shapeMismatch("ran out of tensors at \(name)")
            }
            let entry = entries[cursor]
            let shape = entry["shape"] as? [Int] ?? []
            guard entry["name"] as? String == name, shape == expected else {
                throw ChapterWeightsError.shapeMismatch(
                    "\(name) expected \(expected), header says "
                    + "\(entry["name"] as? String ?? "?") \(shape)")
            }
            let count = shape.reduce(1, *)
            let start = try offset(upTo: cursor)
            guard start + count <= floats.count else {
                throw ChapterWeightsError.truncated(expected: start + count, got: floats.count)
            }
            cursor += 1
            return Array(floats[start..<(start + count)])
        }
        func offset(upTo index: Int) throws -> Int {
            var total = 0
            for i in 0..<index {
                total += (entries[i]["shape"] as? [Int] ?? []).reduce(1, *)
            }
            return total
        }

        let projW = try next("proj.weight", [dim, 773])
        let projB = try next("proj.bias", [dim])
        let normW = try next("norm_in.weight", [dim])
        let normB = try next("norm_in.bias", [dim])

        var layers: [TransformerLayer] = []
        for i in 0..<layerCount {
            let n1w = try next("L\(i).norm1.weight", [dim])
            let n1b = try next("L\(i).norm1.bias", [dim])
            let ipw = try next("L\(i).attn.in_proj_weight", [3 * dim, dim])
            let ipb = try next("L\(i).attn.in_proj_bias", [3 * dim])
            let opw = try next("L\(i).attn.out.weight", [dim, dim])
            let opb = try next("L\(i).attn.out.bias", [dim])
            let n2w = try next("L\(i).norm2.weight", [dim])
            let n2b = try next("L\(i).norm2.bias", [dim])
            let f1w = try next("L\(i).ff1.weight", [ff, dim])
            let f1b = try next("L\(i).ff1.bias", [ff])
            let f2w = try next("L\(i).ff2.weight", [dim, ff])
            let f2b = try next("L\(i).ff2.bias", [dim])
            layers.append(TransformerLayer(
                dim: dim, heads: heads,
                norm1: LayerNorm(weight: n1w, bias: n1b),
                norm2: LayerNorm(weight: n2w, bias: n2b),
                inProjWeight: ipw, inProjBias: ipb,
                outProj: Linear(outFeatures: dim, inFeatures: dim, weight: opw, bias: opb),
                ff1: Linear(outFeatures: ff, inFeatures: dim, weight: f1w, bias: f1b),
                ff2: Linear(outFeatures: dim, inFeatures: ff, weight: f2w, bias: f2b)))
        }

        let outW = try next("out.weight", [1, dim])
        let outB = try next("out.bias", [1])

        return ChapterWeights(
            dim: dim, layers: layers,
            inputProjection: Linear(outFeatures: dim, inFeatures: 773,
                                    weight: projW, bias: projB),
            inputNorm: LayerNorm(weight: normW, bias: normB),
            output: Linear(outFeatures: 1, inFeatures: dim, weight: outW, bias: outB))
    }
}
