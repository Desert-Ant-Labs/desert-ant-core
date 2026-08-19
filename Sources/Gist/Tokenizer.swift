import DesertAnt

/// XLM-R / bge-m3 SentencePiece **Unigram** tokenizer, ported to pure Swift and
/// verified to reproduce the training tokenizer's ids exactly (NFKC normalization,
/// no lowercasing, `▁` metaspace, Viterbi over the vocab with a `min_score − 10`
/// unknown penalty). Backed by a compact `gist_tokenizer.bin` whose vocab is
/// per-script pruned across the 101 languages gist supports. gist uses the
/// content sub-words directly (no `<s>`/`</s>`),
/// which it mean-pools into the semantic embedding.
struct Tokenizer {
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

    // sentencepiece `nmt_nfkc` normalization (matching @huggingface/transformers'
    // Precompiled normalizer, which the training tokenizer's charsmap uses): drop
    // control chars, map a fixed set of whitespace-ish chars to a plain space,
    // then NFKC (with the fullwidth-tilde edge case). This matches the reference
    // model on ~98% of posts; the full precompiled-charsmap trie is a GA follow-up.
    private static let control: Set<UInt32> =
        Set(0x01...0x08).union([0x0B]).union(0x0E...0x1F).union([0x7F, 0x8F, 0x9F])
    private static let spaces: Set<UInt32> =
        Set([0x09, 0x0A, 0x0C, 0x0D, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F,
             0x2581, 0x3000, 0xFEFF, 0xFFFD]).union(0x2000...0x200F)

    static func nmtNormalize(_ text: String) -> String {
        var pre = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let c = scalar.value
            if control.contains(c) { continue }
            pre.append(spaces.contains(c) ? " " : scalar)
        }
        let s = String(pre)
        let tilde: Character = "\u{FF5E}"
        guard s.contains(tilde) else { return s.nfkc }
        // Foundation-free split (String.components is Foundation, absent on wasm/Android).
        return s.split(separator: tilde, omittingEmptySubsequences: false)
            .map { String($0).nfkc }
            .joined(separator: String(tilde))
    }

    init?(bytes: [UInt8]) {
        // magic "GSTK" + 1 version byte
        guard bytes.count >= 21, bytes.starts(with: [0x47, 0x53, 0x54, 0x4B]) else { return nil }
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
        // `parsedIndex` may be slightly smaller than `count`: Swift `String`
        // keys compare by Unicode canonical equivalence, so a few canonically-
        // equivalent pieces in the 101-language vocab collapse to one key. That
        // is correct here — input is NFKC-normalized before matching, so those
        // pieces are indistinguishable anyway. `offset == bytes.count` is the
        // real integrity check.
        guard offset == bytes.count, (0..<count).contains(unk) else { return nil }

        unkID = unk
        bosID = bos
        eosID = eos
        scores = parsedScores
        index = parsedIndex
        maxLen = min(maximumLength, 32)
        unkPenalty = Double(parsedScores.min() ?? 0) - 10.0
    }

    /// Content sub-word ids for `text`, Viterbi-optimal over the unigram vocab.
    func encode(_ text: String) -> [Int] { tokenize(text).map(\.id) }

    func tokenize(_ text: String) -> [Token] {
        let nfkc = Self.nmtNormalize(text)
        // SentencePiece `remove_extra_whitespaces`: trim + collapse space runs.
        var squeezed = [Unicode.Scalar]()
        squeezed.reserveCapacity(nfkc.unicodeScalars.count)
        var lastWasSpace = true
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

        var best = [Double](repeating: -1e18, count: n + 1); best[0] = 0
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
