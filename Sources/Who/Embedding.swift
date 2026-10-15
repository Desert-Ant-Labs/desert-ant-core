import Foundation

/// The trunk's embedding layer from the `who_embed.f16` sidecar, and the pooling that turns a
/// stretch's trunk columns into a unit speaker embedding: mean and unbiased standard deviation
/// of the columns, concatenated, through the layer.
struct Embedding: Sendable {
    /// Row-major `[out * in]`.
    let weight: [Float]
    let bias: [Float]
    let out: Int
    let columns: Int

    /// `[out, in]` as two little-endian UInt32, then the weight rows, then the bias, as little-endian Float16.
    init(sidecar bytes: [UInt8]) throws {
        guard bytes.count >= 8 else { throw WhoError.invalidModel("embedding sidecar is truncated") }
        func u32(_ at: Int) -> Int {
            Int(UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
        }
        let out = u32(0), inner = u32(4)
        guard out > 0, inner > 0, inner % 2 == 0, bytes.count == 8 + 2 * (out * inner + out) else {
            throw WhoError.invalidModel("embedding sidecar of \(out) x \(inner) does not match \(bytes.count) bytes")
        }
        var values = [Float](repeating: 0, count: out * inner + out)
        bytes.withUnsafeBytes { raw in
            for i in 0..<values.count {
                values[i] = Embedding.half(raw.loadUnaligned(fromByteOffset: 8 + 2 * i, as: UInt16.self).littleEndian)
            }
        }
        self.weight = Array(values[0..<(out * inner)])
        self.bias = Array(values[(out * inner)...])
        self.out = out
        self.columns = inner / 2
    }

    /// An IEEE 754 half-precision value as a Float.
    static func half(_ bits: UInt16) -> Float {
        let sign: Float = bits & 0x8000 == 0 ? 1 : -1
        let exponent = Int((bits >> 10) & 0x1F)
        let fraction = Float(bits & 0x03FF)
        switch exponent {
        case 0: return sign * fraction * Float(exp2(-24.0))
        case 0x1F: return fraction == 0 ? sign * .infinity : .nan
        default: return sign * (1 + fraction / 1024) * Float(exp2(Double(exponent - 15)))
        }
    }

    /// Running sums over the columns of one group.
    struct Pool {
        var sum: [Double]
        var squares: [Double]
        var count: Int

        init(columns: Int) {
            sum = [Double](repeating: 0, count: columns)
            squares = [Double](repeating: 0, count: columns)
            count = 0
        }

        /// Adds one column, `values[offset ..< offset + columns]`.
        mutating func add(_ values: [Float], offset: Int) {
            for c in 0..<sum.count {
                let x = Double(values[offset + c])
                sum[c] += x
                squares[c] += x * x
            }
            count += 1
        }
    }

    /// The unit embedding of a pool, or nil for fewer than two columns.
    func embed(_ pool: Pool) -> [Float]? {
        guard pool.count >= 2 else { return nil }
        let n = Double(pool.count)
        var stats = [Float](repeating: 0, count: 2 * columns)
        for c in 0..<columns {
            let mean = pool.sum[c] / n
            let variance = max((pool.squares[c] - n * mean * mean) / (n - 1), 0)
            stats[c] = Float(mean)
            stats[columns + c] = Float(variance.squareRoot())
        }
        var result = bias
        for o in 0..<out {
            var acc: Float = 0
            let row = o * 2 * columns
            for i in 0..<(2 * columns) { acc += weight[row + i] * stats[i] }
            result[o] += acc
        }
        return Linker.unit(result)
    }
}
