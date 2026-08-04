/// Internal span with UTF-16 offsets into the source string (matches the
/// JavaScript/Python reference pipeline's indexing so all ports agree exactly).
struct Span {
    var start: Int
    var end: Int
    var label: String
    var score: Double

    init(_ start: Int, _ end: Int, _ label: String, _ score: Double = 1.0) {
        self.start = start; self.end = end; self.label = label; self.score = score
    }
}

/// UTF-16-indexed view over a string, providing the small set of operations
/// the pipeline needs (character access, slicing, whitespace/word tests,
/// literal search). Pure Swift, identical on every platform.
struct UTF16Text {
    let string: String
    private let units: [UInt16]
    var length: Int { units.count }

    init(_ string: String) {
        self.string = string
        units = Array(string.utf16)
    }

    /// The Unicode scalar at UTF-16 index `i` (BMP; surrogate pairs read as
    /// their leading unit - PII text is effectively all BMP).
    func scalar(at i: Int) -> Unicode.Scalar? {
        guard i >= 0, i < units.count else { return nil }
        return Unicode.Scalar(units[i])
    }

    func slice(_ a: Int, _ b: Int) -> String {
        let lo = max(0, min(a, units.count)), hi = max(0, min(b, units.count))
        guard hi > lo else { return "" }
        return String(decoding: units[lo..<hi], as: UTF16.self)
    }

    /// First literal occurrence of `needle` at or after UTF-16 offset `from`.
    func find(_ needle: String, from: Int) -> (start: Int, end: Int)? {
        let n = Array(needle.utf16)
        guard !n.isEmpty, from <= units.count - n.count else { return nil }
        outer: for i in max(0, from)...(units.count - n.count) {
            for j in 0..<n.count where units[i + j] != n[j] { continue outer }
            return (i, i + n.count)
        }
        return nil
    }

    func isWhitespace(at i: Int) -> Bool {
        guard let s = scalar(at: i) else { return false }
        return s.properties.isWhitespace
    }

    func isWordChar(at i: Int) -> Bool {
        guard let s = scalar(at: i) else { return false }
        if s.properties.isAlphabetic || s.properties.numericType != nil { return true }
        switch s.properties.generalCategory {
        case .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }
}
