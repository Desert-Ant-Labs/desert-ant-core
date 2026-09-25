// The four graphs and the one table that is deliberately not a graph.
//
// Nothing here names a concrete backend. Sessions come from DesertAnt's
// `inferenceSession` factory, which is Core ML on Apple, LiteRT on
// Android/Linux/Windows, and the JS host on wasm. That is the whole reason
// this file exists rather than the model code holding MLModel directly: the
// per-field pipeline in Schemer.swift is then platform-free, and adding a
// platform is a catalog entry plus an exported artifact.
//
// Graphs:
//   encoder(256)  joint [anchor ||| schema ||| text] -> per-token states
//   encoder(32)   field queries and label values -> states
//   decode        reader + every head whose shape does not depend on the
//                 label value set, fused into ONE program (27 outputs)
//   label         dual + prototype logits over N candidate values
//
// The token embedding table is a memory-mapped int8 file, not a fifth graph.
// It is 159 MB against a 2 MB on-chip working set, `gather` has a narrow
// envelope on the Neural Engine, and CPU-only measured fastest for it anyway.
// A lookup is a memcpy; making it a graph added a dispatch and a second copy
// on disk.

import DesertAnt
import Foundation

/// Sequence lengths the artifacts are compiled for.
///
/// Static shapes are a hardware requirement, not a simplification: the Neural
/// Engine has no dynamic shapes, and LiteRT would have to re-plan per length.
enum Shapes {
    /// The compiled text windows, smallest first. A record is dispatched to
    /// the smallest one that holds it.
    ///
    /// 1216 is not optional: 54% of the pooled eval exceeds 256 tokens, and
    /// truncating them costs ~0.15 absolute. The three windows are FUNCTIONS
    /// of one multifunction package, so they cost one copy of the weights
    /// (84.9 MB for all three, against 251.6 MB as separate packages).
    static let windows = [256, 1216]
    static let query = 32
    static let dim = 768
    /// The compiled label graph takes a fixed candidate count.
    static let labelValues = 16

    /// The smallest compiled window that holds `tokens`.
    static func window(for tokens: Int) -> Int {
        windows.first { tokens <= $0 } ?? windows[windows.count - 1]
    }

    static func encodeFunction(_ window: Int) -> String { "encode_\(window)" }
    static func decodeFunction(_ window: Int) -> String { "decode_\(window)" }
}

/// Row lookup over the quantized embedding sidecar.
///
/// `embeddings.q` (see schemer-training/training/ane/embeddings.py) stores
/// per-row symmetric int8 or int4 codes plus a per-row fp16 scale. The row
/// MEAN is not stored: the encoder's first op is a LayerNorm over the channel
/// axis, which removes it. That is also why the table tolerates 8 bits at no
/// measured cost - the same LayerNorm re-standardizes the row and absorbs
/// most of the quantization error before any weight sees it.
///
/// 79.6 MB at int8 against 158.7 MB at fp16, and it was the largest single
/// file in the bundle.
final class EmbeddingTable: @unchecked Sendable {
    private let data: Data
    private let scalesOffset: Int
    private let codesOffset: Int
    let vocab: Int
    let dim: Int
    let bits: Int

    init(data: Data) throws {
        self.data = data
        guard data.count > 20, data[0] == 0x53, data[1] == 0x43,
              data[2] == 0x45, data[3] == 0x4D else {          // "SCEM"
            throw SchemerError.invalidBundle("\(SchemerModel.embeddings): bad magic")
        }
        let bytes = data
        // A header value that does not fit `Int` (32 bits on wasm) cannot
        // describe a table this process could hold.
        func u32(_ i: Int) throws -> Int {
            let v = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8
                | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
            guard let n = Int(exactly: v) else {
                throw SchemerError.invalidBundle("embeddings: header value \(v) out of range")
            }
            return n
        }
        let version = try u32(4)
        guard version == 1 else {
            throw SchemerError.invalidBundle("embeddings: unsupported version \(version)")
        }
        bits = try u32(8); vocab = try u32(12); dim = try u32(16)
        guard bits == 8 || bits == 4 else {
            throw SchemerError.invalidBundle("embeddings: \(bits)-bit not supported")
        }
        // The header is the file's own claim, so the size it implies is
        // computed without overflow: a corrupt self-hosted table must throw,
        // not trap.
        scalesOffset = 20
        let (scales, o1) = vocab.multipliedReportingOverflow(by: 2)
        let (cells, o2) = vocab.multipliedReportingOverflow(by: dim)
        let (codeBits, o3) = cells.multipliedReportingOverflow(by: bits)
        guard !(o1 || o2 || o3), dim > 0, codeBits % 8 == 0 else {
            throw SchemerError.invalidBundle("embeddings: impossible header \(vocab) x \(dim)")
        }
        codesOffset = scalesOffset + scales
        let want = codesOffset + codeBits / 8
        guard data.count == want else {
            throw SchemerError.invalidBundle(
                "embeddings: \(data.count) bytes, expected \(want)")
        }
    }

    /// Gather `ids` into a BC1S `(1, dim, 1, length)` tensor, zero-padded.
    ///
    /// Transposing here keeps the seam BC1S on both sides, so nothing is
    /// permuted between dispatches.
    func gather(_ ids: [Int32], length: Int) -> Tensor {
        var out = [Float](repeating: 0, count: dim * length)
        let rowBytes = dim * bits / 8
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!
            let scales = base.advanced(by: scalesOffset)
                .assumingMemoryBound(to: UInt16.self)
            let codes = base.advanced(by: codesOffset)
                .assumingMemoryBound(to: UInt8.self)
            for (t, id) in ids.prefix(length).enumerated() {
                let row = Int(id)
                guard row >= 0, row < vocab else { continue }
                let scale = Float(Float16(bitPattern: scales[row]))
                let p = codes + row * rowBytes
                if bits == 8 {
                    for c in 0..<dim {
                        out[c * length + t] = Float(Int8(bitPattern: p[c])) * scale
                    }
                } else {
                    // Two signed nibbles per byte, low first.
                    for c in stride(from: 0, to: dim, by: 2) {
                        let b = p[c / 2]
                        let lo = Int8(bitPattern: b & 0x0F)
                        let hi = Int8(bitPattern: b >> 4)
                        out[c * length + t] = Float(lo > 7 ? lo - 16 : lo) * scale
                        out[(c + 1) * length + t] = Float(hi > 7 ? hi - 16 : hi) * scale
                    }
                }
            }
        }
        return Tensor(float32: out, shape: [1, dim, 1, length])
    }
}

/// Additive attention biases, built on the host.
///
/// Building them in-graph needs comparisons and casts that fall off the
/// Neural Engine, and the host already knows the padding length. They arrive
/// additive and ready.
enum Masks {
    /// fp16-representable stand-in for -inf. The engine mishandles IEEE -inf
    /// in softmax: a lane holding NaN takes all the mass.
    static let negative: Float = -40000

    /// mmBERT runs global attention every third layer and a 128-wide local
    /// window elsewhere, so the encoder takes two masks.
    static func encoder(validCount: Int, length: Int) -> (Tensor, Tensor) {
        // Layout is [key][query], key-major, so a padded key is one
        // contiguous row. The 128-wide local band depends only on the length
        // and is built once; per call, only the padded rows change. At the
        // 1216 window this replaces 2 x 1.48M branchy element writes with two
        // memcpys and a fill.
        let n = length * length
        let valid = max(0, min(validCount, length))
        var g = [Float](repeating: 0, count: n)
        var l = band(length)
        let tail = (length - valid) * length
        if tail > 0 {
            g.withUnsafeMutableBufferPointer {
                $0.baseAddress!.advanced(by: valid * length).update(repeating: negative, count: tail)
            }
            l.withUnsafeMutableBufferPointer {
                $0.baseAddress!.advanced(by: valid * length).update(repeating: negative, count: tail)
            }
        }
        return (Tensor(float32: g, shape: [1, length, 1, length]),
                Tensor(float32: l, shape: [1, length, 1, length]))
    }

    /// The local-attention band for `length`: NEG where |key - query| > 64.
    private static let bandLock = NSLock()
    nonisolated(unsafe) private static var bands: [Int: [Float]] = [:]

    private static func band(_ length: Int) -> [Float] {
        bandLock.lock()
        defer { bandLock.unlock() }
        if let b = bands[length] { return b }
        var b = [Float](repeating: 0, count: length * length)
        for key in 0..<length {
            for q in 0..<length where abs(key - q) > 64 { b[key * length + q] = negative }
        }
        bands[length] = b
        return b
    }

    /// Cross-attention key padding for the reader's field query.
    static func query(validCount: Int, length: Int) -> Tensor {
        var b = [Float](repeating: 0, count: length)
        for q in validCount..<length { b[q] = negative }
        return Tensor(float32: b, shape: [1, length, 1, 1])
    }

    /// Mask-mean pooling weights over the text region, so the graph does one
    /// multiply and a reduce instead of a reduce-then-divide that can see a
    /// zero denominator.
    static func pooling(start: Int, end: Int, length: Int) -> Tensor {
        var w = [Float](repeating: 0, count: length)
        let n = Float(max(1, end - start))
        for t in start..<min(end, length) { w[t] = 1 / n }
        return Tensor(float32: w, shape: [1, 1, 1, length])
    }
}

/// Named outputs of one decode run, already widened to Float.
struct Heads: Sendable {
    private let byName: [String: [Float]]

    init(names: [String], tensors: [Tensor]) throws {
        var m = [String: [Float]](minimumCapacity: names.count)
        for (n, t) in zip(names, tensors) {
            guard let v = t.float32Values else {
                throw SchemerError.invalidBundle("output \(n) is not float32")
            }
            m[n] = v
        }
        byName = m
    }

    subscript(_ name: String) -> [Float] { byName[name] ?? [] }

    /// Argmax over the first `n` values of a named output.
    func argmax(_ name: String, _ n: Int) -> Int {
        let v = self[name]
        guard !v.isEmpty else { return 0 }
        var best = 0
        for i in 1..<min(n, v.count) where v[i] > v[best] { best = i }
        return best
    }
}
