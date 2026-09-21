// The mmBERT tokenizer in pure Swift: BPE over a Metaspace pre-tokenization,
// with byte fallback, plus the v53 pruned-vocabulary remap.
//
// Reads `schemer_tokenizer.bin` (format v1, built by
// schemer-training/tools/release/build_tokenizer_sidecar.py) rather than the
// 34 MB tokenizer.json, so there is no JSON parse at load and the tables are
// already in the layout the encoder wants.
//
// Conformance is not optional here: the model was trained on exactly these
// ids, and char offsets are how extracted spans get sliced back out of the
// user's string. `tokenizer_fixtures.json` (1045 cases) is the contract.

import Foundation

/// A token with the half-open range of source scalars it came from.
/// Offsets are in Unicode *scalar* units to match Python's `str` indexing,
/// which is what the fixtures were generated with. A Swift `Character` is a
/// grapheme cluster and would drift on emoji and combining marks.
struct TokenSpan: Sendable {
    let id: Int32
    let start: Int
    let end: Int
}

final class SchemerTokenizer: @unchecked Sendable {

    // Metaspace replacement: U+2581 LOWER ONE EIGHTH BLOCK.
    private static let marker: Unicode.Scalar = "\u{2581}"

    let padID: Int32, eosID: Int32, bosID: Int32, unkID: Int32
    let unkSlim: Int32
    private let vocab: [String]
    private let idOf: [String: Int32]
    /// (left << 32 | right) -> (rank, merged id)
    private let merges: [UInt64: (rank: Int32, id: Int32)]
    private let byteIDs: [Int32]
    private let remap: [Int32]
    /// Added tokens as scalar arrays, longest first. HF matches these in the
    /// RAW text before the normalizer runs, splits on them, and tokenizes each
    /// gap independently. This is not just about `<mask>`: Gemma-family
    /// vocabularies carry "\n" and "\n\n" as added tokens, which is why a
    /// newline both becomes its own token AND makes the next word start a
    /// fresh pre-token with a metaspace marker.
    private let added: [(scalars: [Unicode.Scalar], id: Int32)]
    /// Added tokens with the `special` flag. `skip_special_tokens` drops all
    /// of these, not just <bos>/<eos>/<pad>.
    private let specialIDs: Set<Int32>

    convenience init(sidecar url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        var c = Cursor(data)
        guard try c.bytes(4).elementsEqual("SCTK".utf8) else {
            throw SchemerError.invalidBundle("tokenizer: bad magic, expected SCTK")
        }
        let version = try c.u32()
        guard version == 1 else {
            throw SchemerError.invalidBundle("tokenizer: unsupported format v\(version)")
        }
        padID = try c.i32(); eosID = try c.i32()
        bosID = try c.i32(); unkID = try c.i32()

        let nVocab = try c.count(each: 4)
        var v = [String](); v.reserveCapacity(nVocab)
        var m = [String: Int32](minimumCapacity: nVocab)
        for i in 0..<nVocab {
            let n = try c.count(each: 1)
            let s = String(decoding: try c.bytes(n), as: UTF8.self)
            v.append(s)
            // The vocab has no duplicates, but keep the first if it ever does.
            if m[s] == nil { m[s] = Int32(i) }
        }
        vocab = v; idOf = m

        let nMerges = try c.count(each: 8)
        var pairs = [(UInt32, UInt32)](); pairs.reserveCapacity(nMerges)
        for _ in 0..<nMerges { pairs.append((try c.u32(), try c.u32())) }

        let nBytes = try c.count(each: 4)
        var b = [Int32](repeating: -1, count: nBytes)
        for i in 0..<nBytes { let x = try c.u32(); b[i] = x == 0xFFFF_FFFF ? -1 : try c.id(x) }
        byteIDs = b

        let nOrig = try c.count(each: 4)
        var r = [Int32](repeating: -1, count: nOrig)
        for i in 0..<nOrig { let x = try c.u32(); r[i] = x == 0xFFFF_FFFF ? -1 : try c.id(x) }
        remap = r
        _ = try c.u32()                   // n_slim
        unkSlim = try c.i32()
        _ = try c.u32()                   // n_merges guard
        var mm = [UInt64: (rank: Int32, id: Int32)](minimumCapacity: nMerges)
        for i in 0..<nMerges {
            let (l, rr) = pairs[i]
            let merged = try c.i32()
            mm[UInt64(l) << 32 | UInt64(rr)] = (Int32(i), merged)
        }
        merges = mm

        let nAdded = try c.count(each: 8)
        var a: [(scalars: [Unicode.Scalar], id: Int32)] = []
        a.reserveCapacity(nAdded)
        var sp = Set<Int32>()
        for _ in 0..<nAdded {
            let id = try c.i32()
            let flags = try c.u32()
            if flags & 1 != 0 { sp.insert(id) }   // bit0: special
            let i = Int(id)
            if i >= 0, i < vocab.count, !vocab[i].isEmpty {
                a.append((Array(vocab[i].unicodeScalars), id))
            }
        }
        specialIDs = sp
        // Longest first so "\n\n" wins over "\n".
        a.sort { $0.scalars.count > $1.scalars.count }
        added = a
    }

    /// Map original vocab ids onto pruned embedding rows. Dropped ids become
    /// `unkSlim`, which is what `RemappingEmbedding` does at training time.
    func slim(_ ids: [Int32]) -> [Int32] {
        ids.map { id in
            let i = Int(id)
            guard i >= 0, i < remap.count, remap[i] >= 0 else { return unkSlim }
            return remap[i]
        }
    }

    /// Encode with `<bos>` / `<eos>`, truncating the end to `maxLength`.
    func encode(_ text: String, maxLength: Int) -> [TokenSpan] {
        encodeReportingTruncation(text, maxLength: maxLength).tokens
    }

    /// `encode`, and whether pieces past `maxLength` were dropped.
    func encodeReportingTruncation(_ text: String,
                                   maxLength: Int) -> (tokens: [TokenSpan], truncated: Bool) {
        var out: [TokenSpan] = [TokenSpan(id: bosID, start: 0, end: 0)]
        let body = encodeBody(text)
        // HF truncation=True keeps <bos> + the first maxLength-2 pieces + <eos>.
        let keep = max(0, maxLength - 2)
        out.append(contentsOf: body.prefix(keep))
        out.append(TokenSpan(id: eosID, start: 0, end: 0))
        return (out, body.count > keep)
    }

    /// The pieces without special tokens.
    ///
    /// Splits on added tokens first, then runs the Metaspace + BPE pipeline on
    /// each gap independently, which is what HF does and what makes a word
    /// following a newline get its own leading marker.
    func encodeBody(_ text: String) -> [TokenSpan] {
        let s = Array(text.unicodeScalars)
        var out: [TokenSpan] = []
        var gapStart = 0
        var i = 0
        while i < s.count {
            var hit: (len: Int, id: Int32)? = nil
            for a in added where a.scalars.count <= s.count - i {
                var k = 0
                while k < a.scalars.count, s[i + k] == a.scalars[k] { k += 1 }
                if k == a.scalars.count { hit = (k, a.id); break }
            }
            guard let h = hit else { i += 1; continue }
            if gapStart < i {
                encodeGap(s, gapStart..<i, into: &out)
            }
            out.append(TokenSpan(id: h.id, start: i, end: i + h.len))
            i += h.len
            gapStart = i
        }
        if gapStart < s.count { encodeGap(s, gapStart..<s.count, into: &out) }
        return out
    }

    private func encodeGap(_ s: [Unicode.Scalar], _ range: Range<Int>,
                           into out: inout [TokenSpan]) {
        encodeMetaspace(scalars: Array(s[range]), offset: range.lowerBound, into: &out)
    }

    private func encodeMetaspace(scalars: [Unicode.Scalar], offset: Int,
                                 into out: inout [TokenSpan]) {
        // Normalizer: Replace(" " -> "▁"). Then Metaspace(prepend_scheme:
        // always, split: true) prepends a marker and splits on it, so every
        // pre-token begins with one.
        //
        // Two details that only show up against the fixtures:
        //
        //  * The prepend is skipped on empty input and when the normalized
        //    string already begins with a marker, otherwise " " would encode
        //    as two markers instead of one.
        //  * The prepended marker carries the FIRST source scalar's range,
        //    not an empty one. It usually merges into the following token so
        //    the difference is invisible, but before a character it cannot
        //    merge with (CJK, a leading digit) it stands alone and HF reports
        //    [0, 1). Getting this wrong mis-slices every CJK span by one
        //    character.
        var norm: [(s: Unicode.Scalar, start: Int, end: Int)] = []
        norm.reserveCapacity(scalars.count + 1)
        if let first = scalars.first, first != " ", first != Self.marker {
            norm.append((Self.marker, offset, offset + 1))
        }
        for (i, s) in scalars.enumerated() {
            norm.append((s == " " ? Self.marker : s, offset + i, offset + i + 1))
        }

        var i = 0
        while i < norm.count {
            var j = i + 1
            while j < norm.count, norm[j].s != Self.marker { j += 1 }
            bpe(Array(norm[i..<j]), into: &out)
            i = j
        }
    }

    // MARK: - BPE

    private struct Sym { var id: Int32; var start: Int; var end: Int }

    private func bpe(_ piece: [(s: Unicode.Scalar, start: Int, end: Int)],
                     into out: inout [TokenSpan]) {
        guard !piece.isEmpty else { return }

        // Seed symbols: one per scalar where the vocab has it, otherwise the
        // scalar's UTF-8 bytes as <0xNN> pieces. Byte-fallback symbols all
        // carry the originating scalar's range, so a span that lands mid-byte
        // still slices to a whole character.
        var syms: [Sym] = []
        syms.reserveCapacity(piece.count)
        for p in piece {
            if let id = idOf[String(p.s)] {
                syms.append(Sym(id: id, start: p.start, end: p.end))
            } else {
                for byte in String(p.s).utf8 {
                    let id = byteIDs[Int(byte)]
                    syms.append(Sym(id: id >= 0 ? id : unkID, start: p.start, end: p.end))
                }
            }
        }
        guard syms.count > 1 else {
            for s in syms { out.append(TokenSpan(id: s.id, start: s.start, end: s.end)) }
            return
        }

        // Repeatedly apply the lowest-ranked adjacent merge. O(n^2) worst case
        // on a pre-token, which is bounded by a word, so it does not matter.
        while syms.count > 1 {
            var bestRank = Int32.max
            var bestAt = -1
            var bestID: Int32 = 0
            for k in 0..<(syms.count - 1) {
                let key = UInt64(UInt32(bitPattern: syms[k].id)) << 32
                    | UInt64(UInt32(bitPattern: syms[k + 1].id))
                if let m = merges[key], m.rank < bestRank {
                    bestRank = m.rank; bestAt = k; bestID = m.id
                }
            }
            guard bestAt >= 0 else { break }
            syms[bestAt] = Sym(id: bestID,
                               start: min(syms[bestAt].start, syms[bestAt + 1].start),
                               end: max(syms[bestAt].end, syms[bestAt + 1].end))
            syms.remove(at: bestAt + 1)
        }
        for s in syms { out.append(TokenSpan(id: s.id, start: s.start, end: s.end)) }
    }

    // MARK: - Decoding

    /// Pieces back to text: "▁" to space, then byte-fallback pieces fused.
    func decode(_ ids: [Int32], skipSpecial: Bool = true) -> String {
        var bytes: [UInt8] = []
        for id in ids {
            let i = Int(id)
            guard i >= 0, i < vocab.count else { continue }
            if skipSpecial, specialIDs.contains(id) || id == bosID || id == eosID
                || id == padID { continue }
            let piece = vocab[i]
            if piece.count == 6, piece.hasPrefix("<0x"), piece.hasSuffix(">"),
               let b = UInt8(piece.dropFirst(3).dropLast(), radix: 16) {
                bytes.append(b)
            } else {
                bytes.append(contentsOf: piece.replacingOccurrences(
                    of: String(Self.marker), with: " ").utf8)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Little-endian reader

/// Reads the sidecar, and throws `invalidBundle` rather than trapping on a
/// truncated or corrupt file: a self-hosted bundle is not hash-checked the way
/// a download is, and every count here comes from the file itself.
private struct Cursor {
    let d: Data
    var i: Int
    init(_ d: Data) { self.d = d; self.i = d.startIndex }

    var remaining: Int { d.endIndex - i }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, n <= remaining else { throw Self.truncated }
        defer { i += n }
        return d[i..<(i + n)]
    }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw Self.truncated }
        defer { i += 4 }
        // The sidecar is little-endian; load byte-wise so this does not depend
        // on the buffer being 4-byte aligned.
        return UInt32(d[i]) | UInt32(d[i + 1]) << 8
            | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }

    /// A token id: a u32 that fits the Int32 the pipeline carries ids in.
    mutating func i32() throws -> Int32 { try id(try u32()) }

    func id(_ x: UInt32) throws -> Int32 {
        guard let v = Int32(exactly: x) else {
            throw SchemerError.invalidBundle("tokenizer: id \(x) out of range")
        }
        return v
    }

    /// An item count, checked against what is left of the file at `each`
    /// bytes an item at least, before anything is allocated for it. `Int` is
    /// 32 bits on wasm, so the u32 is converted only if it fits.
    mutating func count(each: Int) throws -> Int {
        guard let n = Int(exactly: try u32()), n <= remaining / each else { throw Self.truncated }
        return n
    }

    static let truncated = SchemerError.invalidBundle("tokenizer: the file is truncated or corrupt")
}
