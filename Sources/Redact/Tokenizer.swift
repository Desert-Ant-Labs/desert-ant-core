import DesertAnt

/// XLM-R SentencePiece **Unigram** tokenizer, ported to pure Swift and verified
/// to reproduce the training tokenizer's ids exactly (NFKC normalization, no
/// lowercasing, `▁` metaspace, Viterbi over the vocab with a `min_score − 10`
/// unknown penalty). Backed by a compact `redact_tokenizer.bin`.
struct Tokenizer {
    /// One content sub-word: its vocab `id` and its surface `text` (the piece
    /// string, which may begin with the `▁` metaspace marker).
    struct Token {
        let id: Int
        let scalars: [Unicode.Scalar]
    }

    let bosID: Int
    let eosID: Int
    let unkID: Int

    private let scores: [Float]
    private let vocab: VocabIndex
    private let unkPenalty: Double
    private let maxLen: Int

    private static let metaspace: Unicode.Scalar = "\u{2581}"  // ▁

    init?(bytes: [UInt8]) {
        guard bytes.count >= 21, bytes.count <= Int(Int32.max),
              bytes.starts(with: [0x52, 0x44, 0x54, 0x4B]) else { return nil }
        var offset = 5

        func readU16() -> Int? {
            guard offset <= bytes.count - 2 else { return nil }
            defer { offset += 2 }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func readU32() -> UInt32? {
            guard offset <= bytes.count - 4 else { return nil }
            defer { offset += 4 }
            return UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }
        func readInt() -> Int? { readU32().map { Int(Int32(bitPattern: $0)) } }

        guard let unk = readInt(), let bos = readInt(), let eos = readInt(),
              let count = readInt(), count > 0,
              count <= (bytes.count - offset) / 6 else { return nil }

        var parsedScores: [Float] = []
        parsedScores.reserveCapacity(count)
        for _ in 0..<count {
            guard let bits = readU32() else { return nil }
            parsedScores.append(Float(bitPattern: bits))
        }

        var lengths: [Int] = []
        lengths.reserveCapacity(count)
        for _ in 0..<count {
            guard let length = readU16() else { return nil }
            lengths.append(length)
        }

        // Pieces are stored back to back to the end of the container, so the
        // index borrows `bytes` as its byte image and records where each piece
        // begins; nothing is copied and no piece becomes a `String`.
        var bounds: [Int32] = []
        bounds.reserveCapacity(count + 1)
        var maximumLength = 1
        for length in lengths {
            guard length <= bytes.count - offset else { return nil }
            bounds.append(Int32(offset))
            // Measured in scalars, because the Viterbi window below is.
            var scalars = 0
            for byte in bytes[offset..<(offset + length)] where byte & 0xC0 != 0x80 {
                scalars += 1
            }
            maximumLength = max(maximumLength, scalars)
            offset += length
        }
        bounds.append(Int32(offset))
        guard offset == bytes.count,
              let index = VocabIndex(image: bytes, bounds: bounds),
              (0..<count).contains(unk), (0..<count).contains(bos), (0..<count).contains(eos)
        else { return nil }

        unkID = unk
        bosID = bos
        eosID = eos
        scores = parsedScores
        vocab = index
        maxLen = min(maximumLength, 32)
        unkPenalty = Double(parsedScores.min() ?? 0) - 10.0
    }

    /// Tokenize `text` into content sub-words (no `<s>` / `</s>`), Viterbi-optimal
    /// over the unigram vocabulary.
    func tokenize(_ text: String) -> [Token] {
        let nfkc = text.nfkc
        // SentencePiece's `remove_extra_whitespaces`: trim and collapse space
        // runs, like the training tokenizer. Offsets are unaffected (they are
        // recovered by scanning the non-space token surfaces in the source
        // text), but masked-out regions tokenize to far fewer pieces.
        var squeezed = [Unicode.Scalar]()
        squeezed.reserveCapacity(nfkc.unicodeScalars.count)
        var lastWasSpace = true  // trims leading spaces
        for scalar in nfkc.unicodeScalars {
            if scalar == " " {
                if lastWasSpace { continue }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            squeezed.append(scalar)
        }
        if squeezed.last == " " { squeezed.removeLast() }
        let normalized = "\u{2581}" + String(String.UnicodeScalarView(
            squeezed.map { $0 == " " ? "\u{2581}" : $0 }))
        // The lattice is indexed by scalar, the vocab is keyed by byte, so carry
        // the text as UTF-8 plus the byte offset each scalar starts at. Built
        // once per call; the O(n × maxLen) inner loop then slices it for free.
        let s = Array(normalized.unicodeScalars)
        let n = s.count
        if n == 0 { return [] }
        let utf8 = Array(normalized.utf8)
        var span = [Int](repeating: 0, count: n + 1)
        for (i, scalar) in s.enumerated() { span[i + 1] = span[i] + utf8Width(scalar) }

        return utf8.withUnsafeBufferPointer { text -> [Token] in
            vocab.withLookup { lookup -> [Token] in
                let neg = -1e18
                var best = [Double](repeating: neg, count: n + 1); best[0] = 0
                var backPos = [Int](repeating: -1, count: n + 1)
                var backID = [Int](repeating: -1, count: n + 1)
                for i in 1...n {
                    let lo = max(0, i - maxLen)
                    for j in lo..<i {
                        let query = UnsafeBufferPointer(rebasing: text[span[j]..<span[i]])
                        if let tid = lookup.id(of: query) {
                            let sc = best[j] + Double(scores[tid])
                            if sc > best[i] { best[i] = sc; backPos[i] = j; backID[i] = tid }
                        }
                    }
                    let cand = best[i - 1] + unkPenalty
                    if cand > best[i] { best[i] = cand; backPos[i] = i - 1; backID[i] = unkID }
                }

                var tokens: [Token] = []
                var i = n
                while i > 0 {
                    let j = backPos[i]
                    tokens.append(Token(id: backID[i], scalars: Array(s[j..<i])))
                    i = j
                }
                return tokens.reversed()
            }
        }
    }
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
/// bytes, so in a `[String: Int]` vocab two byte-distinct pieces that differ only
/// in composition or in combining-mark order are ONE key, and the later id
/// silently evicts the earlier - after which no input can ever produce it.
/// Redact's own pruned 31,475-piece vocab happens to have no such pair today, so
/// this is not a fix to its published ids; it is the same defect that made the
/// full xlm-roberta-base vocab unloadable in `Clips` (29 collapsed keys), and
/// the two tokenizers read the same container from the same builder, so the two
/// must not disagree about what a vocab key is. A re-pruned or re-trained vocab
/// would otherwise reintroduce it silently.
///
/// Bytes are what the container stores and what training matched, so bytes are
/// the key. This is open addressing over the container's own byte image rather
/// than a `[[UInt8]: Int]` dictionary because the decoder probes the vocab
/// O(scalars × maxLen) times per sentence, and an `Array` key would heap-allocate
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

    /// FNV-1a, which is what the container's own tooling hashes with and is
    /// cheap enough to run on every probe.
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
