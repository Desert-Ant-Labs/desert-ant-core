/// The encoder's byte-fallback BPE tokenizer, read from the compact `toxic_tokenizer.bin` (`TXTK` v1) the
/// training repository writes from `tokenizer.json`, and doing exactly what its Python reference does so the ids
/// match training. Encoding a text: split out the added tokens (leftmost, longest), replace spaces with the
/// metaspace `▁` and prepend one, cut at each `▁`, merge each word's characters by merge rank (a character outside
/// the vocabulary becomes its UTF-8 bytes), then `[bos] + pieces[..<window - 2] + [eos]`.
///
/// Container, little-endian: magic `TXTK`, version `1`; `pieces, merges, added, unk, bos, eos, pad, maxLength`
/// as eight `u32`; the pieces as `u16` length + UTF-8 bytes in id order; the merges as `u32` left, right, merged
/// in rank order; the added tokens as `u32` id + `u8` special.
struct Tokenizer {
    let bosID: Int32
    let eosID: Int32
    let padID: Int32
    let unkID: Int32
    /// The window the model reads: bos, up to `maxLength - 2` pieces, eos, then pad.
    let maxLength: Int

    /// Piece id by UTF-8 bytes. Keyed on bytes, not `String`: Swift compares strings by canonical
    /// equivalence, which would fold two byte-distinct pieces into one key.
    private let vocab: [[UInt8]: Int32]
    /// `(left << 32) | right` to `(rank, merged)`.
    private let merges: [UInt64: (rank: Int32, merged: Int32)]
    /// The `<0xNN>` piece of each byte value, or -1 where the vocabulary has none.
    private let byteFallback: [Int32]
    /// The added tokens' contents as scalars with their ids, longest first.
    private let added: [(scalars: [Unicode.Scalar], id: Int32)]

    private static let metaspace: Unicode.Scalar = "\u{2581}"

    init?(bytes: [UInt8]) {
        guard bytes.count >= 37, bytes.starts(with: [0x54, 0x58, 0x54, 0x4B]), bytes[4] == 1 else { return nil }
        var offset = 5

        func u16() -> Int? {
            guard offset + 2 <= bytes.count else { return nil }
            defer { offset += 2 }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func u32() -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            defer { offset += 4 }
            return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
        }

        guard let pieceCount = u32(), let mergeCount = u32(), let addedCount = u32(),
              let unk = u32(), let bos = u32(), let eos = u32(), let pad = u32(), let window = u32(),
              pieceCount > 0, window > 2 else { return nil }

        var pieces: [[UInt8]] = []
        pieces.reserveCapacity(Int(pieceCount))
        var vocab: [[UInt8]: Int32] = [:]
        vocab.reserveCapacity(Int(pieceCount))
        for id in 0..<Int(pieceCount) {
            guard let length = u16(), offset + length <= bytes.count else { return nil }
            let piece = Array(bytes[offset..<(offset + length)])
            offset += length
            pieces.append(piece)
            guard vocab.updateValue(Int32(id), forKey: piece) == nil else { return nil }
        }

        var merges: [UInt64: (rank: Int32, merged: Int32)] = [:]
        merges.reserveCapacity(Int(mergeCount))
        for rank in 0..<Int(mergeCount) {
            guard let left = u32(), let right = u32(), let merged = u32(),
                  left < pieceCount, right < pieceCount, merged < pieceCount else { return nil }
            let key = UInt64(left) << 32 | UInt64(right)
            if merges[key] == nil { merges[key] = (Int32(rank), Int32(merged)) }
        }

        var added: [(scalars: [Unicode.Scalar], id: Int32)] = []
        for _ in 0..<Int(addedCount) {
            guard let id = u32(), id < pieceCount, offset < bytes.count else { return nil }
            offset += 1   // special flag; the encoder treats every added token alike
            added.append((Array(String(decoding: pieces[Int(id)], as: UTF8.self).unicodeScalars), Int32(id)))
        }
        guard offset == bytes.count, unk < pieceCount, bos < pieceCount, eos < pieceCount, pad < pieceCount else { return nil }

        var byteFallback = [Int32](repeating: -1, count: 256)
        for value in 0..<256 {
            let name = Array(String(format: "<0x%02X>", value).utf8)
            if let id = vocab[name] { byteFallback[value] = id }
        }

        self.vocab = vocab
        self.merges = merges
        self.byteFallback = byteFallback
        self.added = added.sorted { $0.scalars.count > $1.scalars.count }
        bosID = Int32(bos)
        eosID = Int32(eos)
        padID = Int32(pad)
        unkID = Int32(unk)
        maxLength = Int(window)
    }

    /// Every piece of `text`, before the template and the window.
    func pieces(of text: String) -> [Int32] {
        var ids: [Int32] = []
        for segment in splitAdded(Array(text.unicodeScalars)) {
            switch segment {
            case .added(let id):
                ids.append(id)
            case .text(let scalars):
                var word: [Unicode.Scalar] = []
                var first = true
                for scalar in scalars {
                    let s = scalar == " " ? Self.metaspace : scalar
                    if first && s != Self.metaspace { word.append(Self.metaspace) }
                    first = false
                    if s == Self.metaspace && !word.isEmpty {
                        ids.append(contentsOf: merge(word))
                        word.removeAll(keepingCapacity: true)
                    }
                    word.append(s)
                }
                if !word.isEmpty { ids.append(contentsOf: merge(word)) }
            }
        }
        return ids
    }

    /// The model's one window for `text`: `[bos] + pieces[..<maxLength - 2] + [eos]`, no padding.
    func encode(_ text: String) -> [Int32] {
        [bosID] + pieces(of: text).prefix(maxLength - 2) + [eosID]
    }

    private enum Segment {
        case text([Unicode.Scalar])
        case added(Int32)
    }

    /// The text cut at its added tokens (leftmost, longest match), which never merge with their neighbours.
    private func splitAdded(_ scalars: [Unicode.Scalar]) -> [Segment] {
        var out: [Segment] = []
        var start = 0
        var i = 0
        while i < scalars.count {
            var hit: (scalars: [Unicode.Scalar], id: Int32)?
            for token in added where i + token.scalars.count <= scalars.count {
                if scalars[i..<(i + token.scalars.count)].elementsEqual(token.scalars) { hit = token; break }
            }
            guard let token = hit else { i += 1; continue }
            if i > start { out.append(.text(Array(scalars[start..<i]))) }
            out.append(.added(token.id))
            i += token.scalars.count
            start = i
        }
        if start < scalars.count { out.append(.text(Array(scalars[start...]))) }
        return out
    }

    /// One word's pieces: its characters, or their bytes where a character is no piece, merged by rank.
    private func merge(_ word: [Unicode.Scalar]) -> [Int32] {
        var ids: [Int32] = []
        for scalar in word {
            let utf8 = Array(String(scalar).utf8)
            if let id = vocab[utf8] {
                ids.append(id)
            } else {
                for byte in utf8 {
                    let id = byteFallback[Int(byte)]
                    ids.append(id >= 0 ? id : unkID)
                }
            }
        }
        while ids.count > 1 {
            var best: (rank: Int32, at: Int, merged: Int32)?
            for i in 0..<(ids.count - 1) {
                if let m = merges[UInt64(UInt32(bitPattern: ids[i])) << 32 | UInt64(UInt32(bitPattern: ids[i + 1]))],
                   best == nil || m.rank < best!.rank {
                    best = (m.rank, i, m.merged)
                }
            }
            guard let found = best else { break }
            ids.replaceSubrange(found.at...(found.at + 1), with: [found.merged])
        }
        return ids
    }
}
