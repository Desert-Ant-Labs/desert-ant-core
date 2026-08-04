// The two tokenizers that turn a phrase into the model's inputs, written in pure
// Swift so they run identically on Apple, Android, and wasm:
//   * `NGram`        script-aware n-grams + FNV hashing -> ngram_* tensors
//   * `SemTokenizer` pruned-unigram (Viterbi) tokenizer -> sem_ids tensor
// The only platform abstraction is Unicode NFKC, from desert-ant-core's
// `TextNormalization` (Foundation on Apple, ICU on Android, `String.normalize`
// on the web); everything else is Swift stdlib scalar arithmetic.
import DesertAnt

@inline(__always)
private func fnv64(_ s: String, seed: UInt64) -> UInt64 {
    var h = (0xCBF2_9CE4_8422_2325 as UInt64) ^ seed
    for b in s.utf8 {
        h ^= UInt64(b)
        h = h &* 0x0000_0100_0000_01B3
    }
    return h
}

enum NGram {
    static func encode(
        _ text: String, nBuckets: UInt32, nHashes: Int, nImportance: UInt32, maxFeatures: Int
    ) -> (buckets: [[Int32]], signs: [[Float]], importance: [Int32]) {
        var fs = feats(text)
        if fs.count > maxFeatures { fs = Array(fs.prefix(maxFeatures)) }
        var buckets = [[Int32]](); var signs = [[Float]](); var importance = [Int32]()
        buckets.reserveCapacity(fs.count); signs.reserveCapacity(fs.count); importance.reserveCapacity(fs.count)
        for x in fs {
            var bk = [Int32](repeating: 0, count: nHashes)
            var sg = [Float](repeating: 0, count: nHashes)
            for k in 0..<nHashes {
                let h = fnv64(x, seed: bucketSeeds[k])
                bk[k] = Int32(h % UInt64(nBuckets))
                sg[k] = ((h >> 63) & 1) == 1 ? 1.0 : -1.0
            }
            buckets.append(bk)
            signs.append(sg)
            importance.append(Int32(fnv64(x, seed: impSeed) % UInt64(nImportance)))
        }
        return (buckets, signs, importance)
    }

    private static let bucketSeeds: [UInt64] = [
        0x9E37_79B9_7F4A_7C15, 0xC2B2_AE3D_27D4_EB4F, 0x1656_67B1_9E37_79F9,
        0x27D4_EB2F_1656_67C5, 0x85EB_CA77_C2B2_AE63,
    ]
    private static let impSeed: UInt64 = 0xFF51_AFD7_ED55_8CCD
    private static let na = (3, 5), nc = (1, 2), nj = (2, 4), ns = (2, 4), ni = (1, 3)

    private static func feats(_ text: String) -> [String] {
        var out: [String] = []
        for run in tokens(normalize(text)) {
            if run.contains(where: isSEA) {
                out += charGrams(run, ns.0, ns.1, "s:")
            } else if run.contains(where: isIndic) {
                let cl = clusters(run)
                out.append("a:" + scalars(run))
                out += clusterGrams(cl, 1, 1, "k:")
                out += clusterGrams([["<"]] + cl + [[">"]], 2, ni.1, "k:")
            } else if run.contains(where: isCJK) {
                var ex: [Unicode.Scalar] = []
                for c in run {
                    if isHangul(c) { out += charGrams(jamo(c), nj.0, nj.1, "j:") }
                    ex.append(c)
                }
                out += charGrams(ex, nc.0, nc.1, "c:")
            } else {
                out.append("w:" + scalars(run))
                out += charGrams(["<"] + run + [">"], na.0, na.1, "g:")
            }
        }
        return out.isEmpty ? ["w:\u{0}"] : out
    }

    private static func scalars(_ s: [Unicode.Scalar]) -> String {
        String(String.UnicodeScalarView(s))
    }

    private static func charGrams(_ s: [Unicode.Scalar], _ lo: Int, _ hi: Int, _ tag: String) -> [String] {
        var r: [String] = []
        var n = lo
        while n <= hi {
            if s.count >= n {
                for i in 0...(s.count - n) { r.append(tag + scalars(Array(s[i..<(i + n)]))) }
            }
            n += 1
        }
        return r
    }

    private static func clusterGrams(_ cl: [[Unicode.Scalar]], _ lo: Int, _ hi: Int, _ tag: String) -> [String] {
        var r: [String] = []
        var n = lo
        while n <= hi {
            if cl.count >= n {
                for i in 0...(cl.count - n) { r.append(tag + scalars(cl[i..<(i + n)].flatMap { $0 })) }
            }
            n += 1
        }
        return r
    }

    private static func normalize(_ text: String) -> String {
        let n = text.nfkc.lowercased()
        return n.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func tokens(_ text: String) -> [[Unicode.Scalar]] {
        var out: [[Unicode.Scalar]] = []; var cur: [Unicode.Scalar] = []
        for s in text.unicodeScalars {
            if isWordScalar(s) { cur.append(s) } else if !cur.isEmpty { out.append(cur); cur = [] }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func clusters(_ s: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        var out: [[Unicode.Scalar]] = []; var cur: [Unicode.Scalar] = []
        for c in s {
            if cur.isEmpty { cur = [c]; continue }
            let p = cur[cur.count - 1].value
            let vir = (0x0900...0x0DFF).contains(p) && ((p & 0xFF) == 0x4D || (p & 0xFF) == 0xCD)
            if isMark(c) || vir { cur.append(c) } else { out.append(cur); cur = [c] }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func jamo(_ c: Unicode.Scalar) -> [Unicode.Scalar] {
        guard isHangul(c) else { return [c] }
        let s = Int(c.value) - 0xAC00
        var r = [Unicode.Scalar(UInt32(0x1100 + s / 588))!, Unicode.Scalar(UInt32(0x1161 + (s % 588) / 28))!]
        if s % 28 != 0 { r.append(Unicode.Scalar(UInt32(0x11A7 + s % 28))!) }
        return r
    }

    private static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark,
             .decimalNumber, .letterNumber, .otherNumber:
            true
        default:
            false
        }
    }

    private static func isMark(_ s: Unicode.Scalar) -> Bool {
        if s.properties.canonicalCombiningClass != .notReordered { return true }
        switch s.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }

    private static func isHangul(_ c: Unicode.Scalar) -> Bool { (0xAC00...0xD7A3).contains(c.value) }
    private static func isCJK(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x2_0000...0x2_A6DF).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0x3040...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v)
            || isHangul(c)
    }
    private static func isSEA(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        return (0x0E00...0x0EFF).contains(v) || (0x1000...0x109F).contains(v) || (0x1780...0x17FF).contains(v)
    }
    private static func isIndic(_ c: Unicode.Scalar) -> Bool { (0x0900...0x0DFF).contains(c.value) }
}

final class SemTokenizer {
    init?(bytes: [UInt8]) {
        guard bytes.count >= 14, bytes[0] == 0x45, bytes[1] == 0x4D, bytes[2] == 0x54, bytes[3] == 0x4B else { return nil }
        var off = 6
        func u32() -> UInt32 {
            let v = UInt32(bytes[off]) | UInt32(bytes[off + 1]) << 8 | UInt32(bytes[off + 2]) << 16 | UInt32(bytes[off + 3]) << 24
            off += 4; return v
        }
        unkID = Int32(bitPattern: u32())
        let k = Int(u32())
        var sc = [Float](); sc.reserveCapacity(k)
        for _ in 0..<k { sc.append(Float(bitPattern: u32())) }
        var lens = [Int](); lens.reserveCapacity(k)
        for _ in 0..<k {
            let v = Int(bytes[off]) | Int(bytes[off + 1]) << 8; off += 2
            lens.append(v)
        }
        var ps = [String](); ps.reserveCapacity(k)
        var idx = [String: Int32](minimumCapacity: k)
        var maxL = 1
        for i in 0..<k {
            let piece = String(decoding: bytes[off..<(off + lens[i])], as: UTF8.self)
            off += lens[i]
            ps.append(piece)
            idx[piece] = Int32(i)
            let n = piece.unicodeScalars.count
            if n > maxL { maxL = n }
        }
        scores = sc
        pieces = ps
        index = idx
        maxLen = min(maxL, 24)
        unkScore = Double(sc[Int(unkID)])
    }

    func encode(_ text: String) -> [Int32] {
        let ms: Character = "\u{2581}"
        let lowered = text.lowercased().nfkc
        let normalized = String([ms] + lowered.map { $0 == " " ? ms : $0 })
        let s = Array(normalized.unicodeScalars)
        let n = s.count
        if n == 0 { return [] }
        let neg = -1e18
        var best = [Double](repeating: neg, count: n + 1); best[0] = 0
        var backPos = [Int](repeating: -1, count: n + 1)
        var backID = [Int32](repeating: -1, count: n + 1)
        for i in 1...n {
            let lo = max(0, i - maxLen)
            for j in lo..<i {
                if let tid = index[String(String.UnicodeScalarView(s[j..<i]))] {
                    let sc = best[j] + Double(scores[Int(tid)])
                    if sc > best[i] { best[i] = sc; backPos[i] = j; backID[i] = tid }
                }
            }
            let cand = best[i - 1] + unkScore
            if cand > best[i] { best[i] = cand; backPos[i] = i - 1; backID[i] = unkID }
        }
        var ids = [Int32](); var i = n
        while i > 0 { ids.append(backID[i]); i = backPos[i] }
        return ids.reversed()
    }

    private let pieces: [String]
    private let scores: [Float]
    private let index: [String: Int32]
    private let unkID: Int32
    private let unkScore: Double
    private let maxLen: Int
}
