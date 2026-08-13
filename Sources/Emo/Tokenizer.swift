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
        // Pieces are stored back to back to the end of the container, so the
        // index borrows `bytes` as its byte image and records where each piece
        // begins; nothing is copied and no piece becomes a `String`.
        var bounds = [Int32](); bounds.reserveCapacity(k + 1)
        var maxL = 1
        for i in 0..<k {
            bounds.append(Int32(off))
            // Measured in scalars, because the Viterbi window below is.
            var scalars = 0
            for byte in bytes[off..<(off + lens[i])] where byte & 0xC0 != 0x80 { scalars += 1 }
            if scalars > maxL { maxL = scalars }
            off += lens[i]
        }
        bounds.append(Int32(off))
        guard bytes.count <= Int(Int32.max), let idx = VocabIndex(image: bytes, bounds: bounds)
        else { return nil }
        scores = sc
        index = idx
        maxLen = min(maxL, 24)
        unkScore = Double(sc[Int(unkID)])
    }

    func encode(_ text: String) -> [Int32] {
        let ms: Character = "\u{2581}"
        let lowered = text.lowercased().nfkc
        let normalized = String([ms] + lowered.map { $0 == " " ? ms : $0 })
        // The lattice is indexed by scalar, the vocab is keyed by byte, so carry
        // the text as UTF-8 plus the byte offset each scalar starts at. Built
        // once per call; the O(n × maxLen) inner loop then slices it for free.
        let s = Array(normalized.unicodeScalars)
        let n = s.count
        if n == 0 { return [] }
        let utf8 = Array(normalized.utf8)
        var span = [Int](repeating: 0, count: n + 1)
        for (i, scalar) in s.enumerated() { span[i + 1] = span[i] + utf8Width(scalar) }

        return utf8.withUnsafeBufferPointer { text -> [Int32] in
            index.withLookup { lookup -> [Int32] in
                let neg = -1e18
                var best = [Double](repeating: neg, count: n + 1); best[0] = 0
                var backPos = [Int](repeating: -1, count: n + 1)
                var backID = [Int32](repeating: -1, count: n + 1)
                for i in 1...n {
                    let lo = max(0, i - maxLen)
                    for j in lo..<i {
                        let query = UnsafeBufferPointer(rebasing: text[span[j]..<span[i]])
                        if let tid = lookup.id(of: query) {
                            let sc = best[j] + Double(scores[tid])
                            if sc > best[i] { best[i] = sc; backPos[i] = j; backID[i] = Int32(tid) }
                        }
                    }
                    let cand = best[i - 1] + unkScore
                    if cand > best[i] { best[i] = cand; backPos[i] = i - 1; backID[i] = unkID }
                }
                var ids = [Int32](); var i = n
                while i > 0 { ids.append(backID[i]); i = backPos[i] }
                return ids.reversed()
            }
        }
    }

    private let scores: [Float]
    private let index: VocabIndex
    private let unkID: Int32
    private let unkScore: Double
    private let maxLen: Int
}

/// How many UTF-8 bytes a scalar occupies, without building a `String` for it.
@inline(__always)
private func utf8Width(_ scalar: Unicode.Scalar) -> Int {
    switch scalar.value {
    case ..<0x80: 1
    case ..<0x800: 2
    case ..<0x1_0000: 3
    default: 4
    }
}

/// The vocabulary, keyed on a piece's UTF-8 **bytes**.
///
/// Swift compares and hashes `String` by Unicode *canonical equivalence*, not by
/// bytes, so in a `[String: Int32]` vocab two byte-distinct pieces that differ
/// only in composition or in combining-mark order are ONE key, and the later id
/// silently evicts the earlier - after which no input can ever produce it. Emo's
/// 48,000-piece vocab has two such pairs, both Vietnamese and both common words:
/// `▁một` (id 688 precomposed, id 39184 as `ô` + combining dot below) and `▁ở`
/// (id 1493, id 41329). The decomposed entry is the higher id, so it won the key
/// and the composed one - the only form NFKC can ever produce - was unreachable,
/// which is why those two words encoded to ids the training tokenizer never
/// assigns them.
///
/// Bytes are what the container stores and what training matched, so bytes are
/// the key. This is open addressing over the container's own byte image rather
/// than a `[[UInt8]: Int32]` dictionary because the decoder probes the vocab
/// O(scalars × maxLen) times per phrase, and an `Array` key would heap-allocate
/// on every probe.
struct VocabIndex {
    /// The whole container, borrowed. Piece `id` is `image[bounds[id]..<bounds[id + 1]]`,
    /// so the pieces cost no storage beyond the bytes already read from disk.
    private let image: [UInt8]
    private let bounds: [Int32]
    /// Open addressing, power-of-two, `-1` where empty; the value is a piece id.
    private let table: [Int32]
    private let mask: Int

    /// Fails when two pieces carry identical bytes, which is a malformed
    /// container rather than a Unicode subtlety.
    init?(image: [UInt8], bounds: [Int32]) {
        let count = bounds.count - 1
        guard count > 0 else { return nil }
        var capacity = 16
        while capacity < count * 2 { capacity <<= 1 }
        var slots = [Int32](repeating: -1, count: capacity)
        let m = capacity - 1

        let duplicate = image.withUnsafeBufferPointer { bytes -> Bool in
            for id in 0..<count {
                let lo = Int(bounds[id]), hi = Int(bounds[id + 1])
                let piece = UnsafeBufferPointer(rebasing: bytes[lo..<hi])
                var slot = VocabIndex.hash(piece) & m
                while slots[slot] >= 0 {
                    let other = Int(slots[slot])
                    let range = Int(bounds[other])..<Int(bounds[other + 1])
                    if range.count == piece.count,
                       UnsafeBufferPointer(rebasing: bytes[range]).elementsEqual(piece) {
                        return true
                    }
                    slot = (slot + 1) & m
                }
                slots[slot] = Int32(id)
            }
            return false
        }
        guard !duplicate else { return nil }

        self.image = image
        self.bounds = bounds
        table = slots
        mask = m
    }

    /// Borrow the index for the length of one tokenization. Everything the inner
    /// loop touches is resolved to a pointer once, so a probe is a hash, a
    /// length compare, and a byte compare - no allocation, no retain.
    func withLookup<R>(_ body: (Lookup) -> R) -> R {
        image.withUnsafeBufferPointer { image in
            bounds.withUnsafeBufferPointer { bounds in
                table.withUnsafeBufferPointer { table in
                    body(Lookup(image: image, bounds: bounds, table: table, mask: mask))
                }
            }
        }
    }

    struct Lookup {
        fileprivate let image: UnsafeBufferPointer<UInt8>
        fileprivate let bounds: UnsafeBufferPointer<Int32>
        fileprivate let table: UnsafeBufferPointer<Int32>
        fileprivate let mask: Int

        /// The id of the piece whose UTF-8 is exactly `query`, or nil.
        func id(of query: UnsafeBufferPointer<UInt8>) -> Int? {
            var slot = VocabIndex.hash(query) & mask
            while true {
                let id = Int(table[slot])
                if id < 0 { return nil }
                let lo = Int(bounds[id]), hi = Int(bounds[id + 1])
                if hi - lo == query.count,
                   UnsafeBufferPointer(rebasing: image[lo..<hi]).elementsEqual(query) {
                    return id
                }
                slot = (slot + 1) & mask
            }
        }
    }

    /// FNV-1a, the same hash `NGram` above uses, cheap enough to run on every
    /// probe.
    @inline(__always)
    fileprivate static func hash(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in bytes {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        return Int(truncatingIfNeeded: h) & Int.max
    }
}
