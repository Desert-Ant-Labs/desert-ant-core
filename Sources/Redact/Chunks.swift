/// How the text is cut before the model sees it.
///
/// The model was trained on short strings. Inside a long passage the PII-free
/// context around a name pulls its score under the threshold, so a 45-word email
/// can lose every name that it finds one sentence at a time. Packing whole
/// sentences into short chunks keeps each pass close to the training length.
struct Chunking: Sendable, Equatable {
    /// Pack whole sentences up to this many UTF-16 units. A sentence longer than
    /// this is cut at word boundaries. `Int.max` is the whole text in one chunk.
    var maxChars: Int
    /// Trailing sentences of each chunk repeated at the start of the next, so an
    /// entity next to a boundary is still seen with context on both sides.
    var carry: Int

    static let `default` = Chunking(maxChars: 150, carry: 1)
    static let whole = Chunking(maxChars: .max, carry: 0)
}

enum Chunks {
    /// UTF-16 ranges of `t` to run through the model, in order. Ranges overlap
    /// when `carry` > 0; together they cover every non-whitespace unit.
    static func ranges(_ t: UTF16Text, _ c: Chunking) -> [Range<Int>] {
        guard t.length > c.maxChars else { return t.length == 0 ? [] : [0..<t.length] }
        let pieces = sentences(t).flatMap { cut($0, t, max(1, c.maxChars)) }
        var out: [Range<Int>] = []
        var i = 0
        while i < pieces.count {
            var j = i
            while j + 1 < pieces.count, pieces[j + 1].upperBound - pieces[i].lowerBound <= c.maxChars { j += 1 }
            out.append(pieces[i].lowerBound..<pieces[j].upperBound)
            if j == pieces.count - 1 { break }
            i = max(i + 1, j + 1 - c.carry)
        }
        return out
    }

    private static let terminators: Set<UInt16> = Set(".!?\u{2026}\u{037E}\u{0589}\u{061F}\u{06D4}\u{0964}\u{0965}".utf16)
    // CJK full stops end a sentence with no space after them.
    private static let spaceless: Set<UInt16> = Set("\u{3002}\u{FF01}\u{FF1F}\u{FF0E}".utf16)
    private static let closers: Set<UInt16> = Set(")]}\"'\u{2019}\u{201D}\u{00BB}\u{300D}\u{300F}".utf16)
    // A period after these does not end the sentence: "Dr. Emily Chen" must stay whole.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "mx", "dr", "prof", "st", "jr", "sr", "sra", "srta", "mme", "mlle",
        "hr", "fr", "dhr", "mevr", "sig", "nr", "vs", "etc", "eg", "ie", "inc", "ltd", "co",
    ]

    /// Sentence ranges, trimmed of surrounding whitespace. Line breaks always end
    /// one, so chat logs and transcripts split per line.
    static func sentences(_ t: UTF16Text) -> [Range<Int>] {
        let units = Array(t.string.utf16)
        let n = units.count
        let newline = UInt16(UInt8(ascii: "\n")), period = UInt16(UInt8(ascii: "."))
        var out: [Range<Int>] = []
        var start = 0
        func emit(_ end: Int) {
            var s = start, e = end
            while s < e, t.isWhitespace(at: s) { s += 1 }
            while e > s, t.isWhitespace(at: e - 1) { e -= 1 }
            if e > s { out.append(s..<e) }
            start = end
        }
        var i = 0
        while i < n {
            let u = units[i]
            if u == newline {
                emit(i)
            } else if spaceless.contains(u) {
                var e = i + 1
                while e < n, closers.contains(units[e]) { e += 1 }
                emit(e)
                i = e
                continue
            } else if terminators.contains(u) {
                var e = i + 1
                while e < n, terminators.contains(units[e]) || closers.contains(units[e]) { e += 1 }
                if e == n || t.isWhitespace(at: e), !(u == period && isAbbreviation(t, before: i)) {
                    emit(e)
                    i = e
                    continue
                }
            }
            i += 1
        }
        emit(n)
        return out
    }

    /// The word before a period at `i` is a title, a known abbreviation, or a
    /// single letter (an initial, as in "J. Smith").
    private static func isAbbreviation(_ t: UTF16Text, before i: Int) -> Bool {
        var s = i
        while s > 0, t.isWordChar(at: s - 1) || t.scalar(at: s - 1) == "." { s -= 1 }
        let word = t.slice(s, i).filter { $0 != "." }
        if word.count == 1, word.first!.isLetter { return true }
        return abbreviations.contains(word.lowercased())
    }

    /// Split a sentence longer than `limit` at the last whitespace before each
    /// cut, or hard at `limit` when a run has none.
    private static func cut(_ r: Range<Int>, _ t: UTF16Text, _ limit: Int) -> [Range<Int>] {
        guard r.count > limit else { return [r] }
        var out: [Range<Int>] = []
        var s = r.lowerBound
        while r.upperBound - s > limit {
            var e = s + limit
            while e > s + 1, !t.isWhitespace(at: e) { e -= 1 }
            if e <= s + 1 { e = s + limit }
            out.append(s..<e)
            s = e
            while s < r.upperBound, t.isWhitespace(at: s) { s += 1 }
        }
        if s < r.upperBound { out.append(s..<r.upperBound) }
        return out
    }
}
