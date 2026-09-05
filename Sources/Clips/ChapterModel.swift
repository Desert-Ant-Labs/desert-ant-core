import Foundation
import DesertAnt
import Transcript

/// The chapter model: a small sequence model over the trunk's per-sentence `pooled` output.
///
/// WHY IT IS A SEPARATE MODULE FROM `Model`. `Model` owns the clips graph, whose contract is
/// three per-sentence scalars and one per-span score. Chapters read a fourth output that the
/// clips path never looks at, and run a second network over the whole sequence rather than
/// per batch. Folding that into `Model` would put a sequence model behind a type whose every
/// other method is stateless per batch.
///
/// WHY THE TRUNK IS SHARED AND NOT DUPLICATED. `pooled` is the tensor the saliency, start and
/// end heads are already applied to, so emitting it costs one extra output on a pass the
/// transcript view already makes for clips. The TRUNK is therefore effectively free when
/// clips run too; asked for on their own, chapters still pay it once.
///
/// THE HEAD IS CHEAP, BUT ONLY BECAUSE IT WAS MEASURED. An earlier version of this comment
/// asserted the head was "microseconds" next to the trunk with nothing under the claim. At
/// shipping geometry (dim 256, ff 1024, 2 layers) in scalar Swift it was 0.581 s at 400
/// sentences and 1.162 s at 800, i.e. a quarter of the trunk budget on desktop silicon and
/// worse on a phone.
///
/// Routing the matmuls through `Matmul` (Accelerate BLAS on Apple, a triple loop elsewhere)
/// made it about 73x faster. Measured on an M3 Ultra, release build:
///
///     n         100      200      400      800
///     scalar    0.093 s  0.387 s  0.581 s  1.162 s
///     BLAS      0.003 s  0.005 s  0.008 s  0.016 s
///
/// At 800 sentences the head is now 0.7% of a ~2.4 s trunk pass, so the original claim is
/// finally true. `forwardMatchesPyTorch` passes unchanged across the rewrite, which is what
/// establishes that this is the same network and not merely a faster one.
///
/// THE ARTIFACT MUST EMIT `pooled`. Packages built before the chapters work expose `select`
/// with three outputs, and asking for a fourth fails at the runtime boundary rather than
/// silently returning zeros. ``supportsChapters`` is the cheap check.
final class ChapterModel: @unchecked Sendable {
    /// Input width of the head: 768 trunk hidden + the 5 discourse scalars. Must equal
    /// `clip_graphs.POOLED_DIM` in clips-training, which asserts it against the live graph.
    static let pooledDim = 773

    /// Sentences per forward pass of the sequence model. Matches `train_chapters.py --window`.
    /// Transcripts longer than this are tiled with an overlap; see ``boundaryLogits``.
    static let window = 192

    /// Overlap between tiles. A position at a tile edge has half its context missing, so
    /// tiles overlap and each position takes the estimate from the tile where it sits
    /// furthest from an edge. Matches `probe_chapters.logits_for`.
    static let overlap = 48

    private let weights: ChapterWeights

    init(weights: ChapterWeights) {
        self.weights = weights
    }

    /// Per-sentence boundary logits, PRE-SIGMOID.
    ///
    /// Deliberately not probabilities. `ChapterConstruction.partition` maximises a sum of raw
    /// logits, because the per-sentence Bernoulli log-likelihood over a boundary set reduces
    /// to exactly that plus a constant. Converting to probabilities here would force the DP to
    /// convert back.
    func boundaryLogits(pooled: [[Float]]) -> [Double] {
        let n = pooled.count
        guard n > 0 else { return [] }
        if n <= Self.window {
            return weights.forward(pooled).map(Double.init)
        }

        var out = [Double](repeating: -.infinity, count: n)
        var best = [Double](repeating: -.infinity, count: n)
        let step = max(1, Self.window - Self.overlap)
        var lo = 0
        while true {
            let hi = min(lo + Self.window, n)
            let start = max(0, hi - Self.window)
            let logits = weights.forward(Array(pooled[start..<hi]))
            let centre = Double(start + hi) / 2
            for i in start..<hi {
                let centrality = 1 - abs(Double(i) - centre) / max(Double(Self.window) / 2, 1)
                if centrality > best[i] {
                    out[i] = Double(logits[i - start])
                    best[i] = centrality
                }
            }
            if hi >= n { break }
            lo += step
        }
        return out
    }
}

/// The chapter head's weights and forward pass.
///
/// Kept as explicit matrices rather than a second compiled graph. The model is ~1.8M
/// parameters against the trunk's 278M, so a Core ML round-trip and its buffer management
/// plausibly cost more than the arithmetic, and a second graph is another artifact to version,
/// gate and keep in sync. What was NOT defensible was doing the arithmetic scalar: see the
/// latency note on `ChapterModel`. The matmuls now go through `Matmul`, which is Accelerate
/// BLAS on Apple and a triple loop elsewhere.
///
/// EVERYTHING IS FLAT. Weights and activations are `[Float]` in row-major order rather than
/// `[[Float]]`, because BLAS needs contiguous storage and an array of arrays is neither
/// contiguous nor cheap to make so. The public entry point still takes `[[Float]]` since that
/// is what the caller has, and flattens once.
struct ChapterWeights: Sendable {
    let dim: Int
    let layers: [TransformerLayer]
    let inputProjection: Linear
    let inputNorm: LayerNorm
    let output: Linear

    /// `[n, 773]` in, `[n]` boundary logits out.
    func forward(_ pooled: [[Float]]) -> [Float] {
        let n = pooled.count
        guard n > 0 else { return [] }
        let dIn = inputProjection.inFeatures
        var flat = [Float](repeating: 0, count: n * dIn)
        for (i, row) in pooled.enumerated() {
            precondition(row.count == dIn, "expected \(dIn) features, got \(row.count)")
            flat.withUnsafeMutableBufferPointer { out in
                row.withUnsafeBufferPointer { src in
                    out.baseAddress!.advanced(by: i * dIn)
                        .update(from: src.baseAddress!, count: dIn)
                }
            }
        }
        return forwardFlat(flat, count: n)
    }

    func forwardFlat(_ input: [Float], count n: Int) -> [Float] {
        var h = [Float](repeating: 0, count: n * dim)
        Matmul.linear(input, weight: inputProjection.weight, bias: inputProjection.bias,
                      into: &h, m: n, n: dim, k: inputProjection.inFeatures)
        Matmul.layerNormRows(&h, rows: n, cols: dim,
                             weight: inputNorm.weight, bias: inputNorm.bias)
        addSinusoidalPositions(&h, rows: n)
        for layer in layers { layer.apply(&h, rows: n) }

        var logits = [Float](repeating: 0, count: n)
        Matmul.linear(h, weight: output.weight, bias: output.bias,
                      into: &logits, m: n, n: 1, k: dim)
        return logits
    }

    /// Absolute position over SENTENCE index, added to the projected embeddings.
    ///
    /// Sinusoidal rather than learned, matching `chapters_model.SinusoidalPosition`, because
    /// transcript length spans two orders of magnitude and a learned table would be
    /// undertrained at the long end and would cap the length the model accepts at all.
    private func addSinusoidalPositions(_ h: inout [Float], rows: Int) {
        h.withUnsafeMutableBufferPointer { buf in
            for pos in 0..<rows {
                let row = buf.baseAddress! + pos * dim
                var i = 0
                while i < dim {
                    let angle = Double(pos) / pow(10000.0, Double(i) / Double(dim))
                    row[i] += Float(sin(angle))
                    if i + 1 < dim { row[i + 1] += Float(cos(angle)) }
                    i += 2
                }
            }
        }
    }
}

/// One pre-norm transformer encoder layer, operating in place on a flat `[rows, dim]` buffer.
///
/// PRE-NORM, matching `chapters_model.py`'s `norm_first=True`. The residual is added to the
/// UNNORMALISED input and the norm is applied before each sublayer. Getting that order wrong
/// produces a model that runs, returns plausible-looking logits, and is quietly a different
/// network from the one that was trained.
struct TransformerLayer: Sendable {
    let dim: Int
    let heads: Int
    let norm1: LayerNorm
    let norm2: LayerNorm
    let inProjWeight: [Float]   // [3*dim, dim], packed Q|K|V as PyTorch stores it
    let inProjBias: [Float]
    let outProj: Linear
    let ff1: Linear
    let ff2: Linear

    func apply(_ h: inout [Float], rows n: Int) {
        let headDim = dim / heads
        let scale = 1 / Float(headDim).squareRoot()

        var normed = h
        Matmul.layerNormRows(&normed, rows: n, cols: dim,
                             weight: norm1.weight, bias: norm1.bias)

        // One GEMM for Q, K and V together: PyTorch packs them into a single [3*dim, dim]
        // projection, and splitting it here would be three GEMMs over the same input.
        var qkv = [Float](repeating: 0, count: n * 3 * dim)
        Matmul.linear(normed, weight: inProjWeight, bias: inProjBias,
                      into: &qkv, m: n, n: 3 * dim, k: dim)

        var context = [Float](repeating: 0, count: n * dim)
        var q = [Float](repeating: 0, count: n * headDim)
        var k = q, v = q
        var scores = [Float](repeating: 0, count: n * n)
        var headOut = [Float](repeating: 0, count: n * headDim)

        for head in 0..<heads {
            let base = head * headDim
            // Gather this head's slice into contiguous buffers. The copy is O(n * headDim)
            // against a GEMM of O(n^2 * headDim), so it is noise, and it keeps every BLAS call
            // on tightly packed memory.
            qkv.withUnsafeBufferPointer { src in
                for r in 0..<n {
                    let row = src.baseAddress! + r * 3 * dim
                    q.withUnsafeMutableBufferPointer {
                        $0.baseAddress!.advanced(by: r * headDim)
                            .update(from: row + base, count: headDim)
                    }
                    k.withUnsafeMutableBufferPointer {
                        $0.baseAddress!.advanced(by: r * headDim)
                            .update(from: row + dim + base, count: headDim)
                    }
                    v.withUnsafeMutableBufferPointer {
                        $0.baseAddress!.advanced(by: r * headDim)
                            .update(from: row + 2 * dim + base, count: headDim)
                    }
                }
            }
            Matmul.scores(q, k, into: &scores, rows: n, dim: headDim, scale: scale)
            Matmul.softmaxRows(&scores, rows: n, cols: n)
            Matmul.gemm(scores, v, into: &headOut, m: n, n: headDim, k: n)
            context.withUnsafeMutableBufferPointer { dst in
                headOut.withUnsafeBufferPointer { src in
                    for r in 0..<n {
                        dst.baseAddress!.advanced(by: r * dim + base)
                            .update(from: src.baseAddress! + r * headDim, count: headDim)
                    }
                }
            }
        }

        var projected = [Float](repeating: 0, count: n * dim)
        Matmul.linear(context, weight: outProj.weight, bias: outProj.bias,
                      into: &projected, m: n, n: dim, k: dim)
        for i in 0..<(n * dim) { h[i] += projected[i] }

        var normed2 = h
        Matmul.layerNormRows(&normed2, rows: n, cols: dim,
                             weight: norm2.weight, bias: norm2.bias)
        let ff = ff1.outFeatures
        var hidden = [Float](repeating: 0, count: n * ff)
        Matmul.linear(normed2, weight: ff1.weight, bias: ff1.bias,
                      into: &hidden, m: n, n: ff, k: dim)
        Matmul.gelu(&hidden)
        var back = [Float](repeating: 0, count: n * dim)
        Matmul.linear(hidden, weight: ff2.weight, bias: ff2.bias,
                      into: &back, m: n, n: dim, k: ff)
        for i in 0..<(n * dim) { h[i] += back[i] }
    }
}
