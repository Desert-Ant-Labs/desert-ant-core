import TextNormalization

enum Lexical {
    static let context = 16
    static let padByte: Int32 = 256

    static func normalize(_ s: String) -> [UInt8] {
        let trimmed = s.drop(while: { $0.isWhitespace || $0.isNewline })
        let end = trimmed.lastIndex(where: { !($0.isWhitespace || $0.isNewline) }).map { trimmed.index(after: $0) } ?? trimmed.startIndex
        return Array(String(trimmed[trimmed.startIndex..<end]).nfc.utf8)
    }

    /// 32-length byte ids: [preceding last 16 | following first 16], PAD-filled.
    static func bytes(preceding: String, following: String) -> [Int32] {
        var out = [Int32](repeating: padByte, count: 2 * context)
        let pk = Array(normalize(preceding).suffix(context))
        let fk = Array(normalize(following).prefix(context))
        for i in 0..<pk.count { out[context - pk.count + i] = Int32(pk[i]) }
        for i in 0..<fk.count { out[context + i] = Int32(fk[i]) }
        return out
    }
}
