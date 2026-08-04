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
    private let index: [String: Int]
    private let unkPenalty: Double
    private let maxLen: Int

    private static let metaspace: Unicode.Scalar = "\u{2581}"  // ▁

    init?(bytes: [UInt8]) {
        guard bytes.count >= 21, bytes.starts(with: [0x52, 0x44, 0x54, 0x4B]) else { return nil }
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

        var parsedIndex = [String: Int](minimumCapacity: count)
        var maximumLength = 1
        for (id, length) in lengths.enumerated() {
            guard length <= bytes.count - offset else { return nil }
            let piece = String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
            offset += length
            parsedIndex[piece] = id
            maximumLength = max(maximumLength, piece.unicodeScalars.count)
        }
        guard offset == bytes.count, parsedIndex.count == count,
              (0..<count).contains(unk), (0..<count).contains(bos), (0..<count).contains(eos) else { return nil }

        unkID = unk
        bosID = bos
        eosID = eos
        scores = parsedScores
        index = parsedIndex
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
        let s = Array(normalized.unicodeScalars)
        let n = s.count
        if n == 0 { return [] }

        let neg = -1e18
        var best = [Double](repeating: neg, count: n + 1); best[0] = 0
        var backPos = [Int](repeating: -1, count: n + 1)
        var backID = [Int](repeating: -1, count: n + 1)
        for i in 1...n {
            let lo = max(0, i - maxLen)
            for j in lo..<i {
                if let tid = index[String(String.UnicodeScalarView(s[j..<i]))] {
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
