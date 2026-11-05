import Foundation

/// The encoder's embedding table from `toxic_table.bin` (`TXTB` v1): every row palettized to 4-bit, sixteen rows
/// sharing one palette of sixteen float16 values. The SDK looks the rows up itself and feeds the graph embeddings,
/// so the graph has no lookup and runs on the Neural Engine whole; the rows are the ones the published weights hold,
/// value for value.
///
/// Container, little-endian: magic `TXTB`, version `1`; `rows, cols, group, levels` as four `u32`; the palettes as
/// `rows / group` x `levels` float16; the indices as `rows` x `cols` nibbles, two per byte, the first value in the
/// low nibble. Row `r` reads palette `r / group`, and column `c` is `palette[index[r, c]]`.
struct Table {
    let rows: Int
    let cols: Int
    private let group: Int
    private let levels: Int
    /// Every palette's values as Float, `[groups * levels]`.
    private let palettes: [Float]
    /// The container, borrowed for the indices; `indicesOffset` is where they start.
    private let bytes: [UInt8]
    private let indicesOffset: Int

    init?(bytes: [UInt8]) {
        guard bytes.count >= 21, bytes.starts(with: [0x54, 0x58, 0x54, 0x42]), bytes[4] == 1 else { return nil }
        func u32(_ at: Int) -> Int {
            Int(UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
        }
        let rows = u32(5), cols = u32(9), group = u32(13), levels = u32(17)
        guard rows > 0, cols > 0, cols % 2 == 0, group > 0, rows % group == 0, levels == 16 else { return nil }
        let groups = rows / group
        let palettesBytes = groups * levels * 2
        let indicesBytes = rows * cols / 2
        guard bytes.count == 21 + palettesBytes + indicesBytes else { return nil }
        var palettes = [Float](repeating: 0, count: groups * levels)
        bytes.withUnsafeBytes { raw in
            for i in 0..<palettes.count {
                palettes[i] = Table.half(raw.loadUnaligned(fromByteOffset: 21 + 2 * i, as: UInt16.self).littleEndian)
            }
        }
        self.rows = rows
        self.cols = cols
        self.group = group
        self.levels = levels
        self.palettes = palettes
        self.bytes = bytes
        indicesOffset = 21 + palettesBytes
    }

    /// The rows of `ids`, concatenated: `[ids.count * cols]`, an id outside the table as zeros.
    func rows(of ids: [Int32]) -> [Float] {
        var out = [Float](repeating: 0, count: ids.count * cols)
        let half = cols / 2
        bytes.withUnsafeBufferPointer { raw in
            for (t, id) in ids.enumerated() {
                let r = Int(id)
                guard r >= 0, r < rows else { continue }
                let palette = (r / group) * levels
                let start = indicesOffset + r * half
                let base = t * cols
                for c in 0..<half {
                    let byte = Int(raw[start + c])
                    out[base + 2 * c] = palettes[palette + (byte & 0xF)]
                    out[base + 2 * c + 1] = palettes[palette + (byte >> 4)]
                }
            }
        }
        return out
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
}
