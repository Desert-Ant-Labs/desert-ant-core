import Foundation

/// UTF-8 byte lexical features matching align-training docs/lexical.md.
/// NFC normalize, strip whitespace, UTF-8, truncate from the boundary outward
/// (preceding = last 16 bytes, following = first 16 bytes), pad to 16 with PAD_BYTE.
/// No lowercasing (locale-dependent case folding is not portable).
enum Lexical {
    static let context = 16
    static let padByte: Int32 = 256

    static func normalize(_ s: String) -> [UInt8] {
        Array(s.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.utf8)
    }

    /// 32-length byte ids: [preceding last 16 | following first 16], PAD-filled.
    static func bytes(preceding: String, following: String) -> [Int32] {
        var out = [Int32](repeating: padByte, count: 2 * context)
        let p = normalize(preceding)
        let f = normalize(following)
        let pk = Array(p.suffix(context))       // keep trailing bytes of preceding
        let fk = Array(f.prefix(context))        // keep leading bytes of following
        for i in 0..<pk.count { out[context - pk.count + i] = Int32(pk[i]) }  // right-align
        for i in 0..<fk.count { out[context + i] = Int32(fk[i]) }             // left-align
        return out
    }
}
