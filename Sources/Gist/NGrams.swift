// Lexical stream: hashed word + character n-grams. Must match the Python
// `ngram_feats.py` / gist-js `ngrams.ts` exactly: lowercase, split on ASCII
// `[a-z0-9']+`, take word unigrams + word bigrams + char 3/4/5-grams inside
// `^word$`, CRC-32 each into a fixed-dim vector, then L2-normalize.

enum NGrams {
    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for n in 0..<256 {
            var c = UInt32(n)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
            table[n] = c
        }
        return table
    }()

    /// zlib.crc32-compatible unsigned CRC-32 of a string's UTF-8 bytes.
    private static func crc32(_ s: String) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in s.utf8 { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func isWordScalar(_ v: UInt32) -> Bool {
        (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) || v == 0x27  // a-z, 0-9, '
    }

    /// ASCII `[a-z0-9']+` words of the lowercased text (non-ASCII acts as a delimiter,
    /// matching the reference regex).
    private static func words(_ text: String) -> [String] {
        var out: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            if isWordScalar(scalar.value) {
                current.append(scalar)
            } else if !current.isEmpty {
                out.append(String(current)); current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    static func features(_ text: String, dim: Int) -> [Float] {
        let ws = words(text)
        var grams: [String] = ws
        for i in 0..<max(0, ws.count - 1) { grams.append("\(ws[i])_\(ws[i + 1])") }
        for w in ws {
            let s = Array("^\(w)$")
            for n in [3, 4, 5] where s.count >= n {
                for i in 0...(s.count - n) { grams.append(String(s[i..<i + n])) }
            }
        }
        var v = [Float](repeating: 0, count: dim)
        for g in grams { v[Int(crc32(g) % UInt32(dim))] += 1 }
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        if norm > 0 { for i in 0..<dim { v[i] /= norm } }
        return v
    }
}
