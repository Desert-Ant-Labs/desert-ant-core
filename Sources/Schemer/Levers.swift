// Harness rules added after 1.0.0, each measured on the pooled eval through
// this pipeline (schemer-training bench/swift/). Every rule has a name so an
// eval can switch it off and measure it again; apps never touch this.

import Foundation

enum Levers {
    /// Names of the rules switched off. Empty in apps.
    nonisolated(unsafe) static var disabled: Set<String> = []

    static func on(_ name: String) -> Bool { !disabled.contains(name) }

    // MARK: - Word edges

    /// Letters and digits of scripts that separate words with spaces. Han,
    /// kana and Hangul are excluded: extending across them would swallow the
    /// rest of the sentence, since nothing marks a word end.
    static func isWordScalar(_ c: Unicode.Scalar) -> Bool {
        let v = c.value
        if (0x3040...0x30FF).contains(v) || (0x3400...0x9FFF).contains(v)
            || (0xAC00...0xD7AF).contains(v) || (0xF900...0xFAFF).contains(v)
            || (0xFF00...0xFFEF).contains(v) { return false }
        return CharacterSet.alphanumerics.contains(c)
    }

    /// Grow a scalar range to whole words. The tagger reads subword tokens,
    /// and a span that stops inside a word ("Fig" for "Figma", "b82a9-f" for
    /// "b82a9-f12") is never the answer: the model found the word and the
    /// token boundary cut it.
    static func snapToWords(_ scalars: [Unicode.Scalar], lo: Int, hi: Int) -> (Int, Int) {
        var lo = lo, hi = hi
        while lo > 0, lo < scalars.count, isWordScalar(scalars[lo - 1]), isWordScalar(scalars[lo]) {
            lo -= 1
        }
        while hi < scalars.count, hi > 0, isWordScalar(scalars[hi]), isWordScalar(scalars[hi - 1]) {
            hi += 1
        }
        return (lo, hi)
    }

    /// Scalar range of a token run, before any trimming.
    static func range(tokens: [TokenSpan], run: ClosedRange<Int>) -> (Int, Int)? {
        let lo = max(0, run.lowerBound), hi = min(run.upperBound, tokens.count - 1)
        guard lo <= hi else { return nil }
        let spans = tokens[lo...hi].filter { $0.end > $0.start }
        guard let a = spans.map(\.start).min(), let b = spans.map(\.end).max(), a < b else {
            return nil
        }
        return (a, b)
    }

    /// `Harness.slice`, with the span grown to whole words when `snap`.
    static func slice(_ text: String, tokens: [TokenSpan], run: ClosedRange<Int>,
                      snap: Bool) -> String? {
        guard snap else { return Harness.slice(text, tokens: tokens, run: run) }
        let scalars = Array(text.unicodeScalars)
        guard let (a, b) = range(tokens: tokens, run: run), a >= 0, b <= scalars.count
        else { return nil }
        let (lo, hi) = snapToWords(scalars, lo: a, hi: b)
        return Harness.trim(String(String.UnicodeScalarView(scalars[lo..<hi])))
    }

    // MARK: - A span when the gate says present

    /// When the presence gate says the field is stated but no token is tagged
    /// B or I, the tagger was unsure rather than empty: long answers such as
    /// summaries spread probability over many tokens and none clears O. Take
    /// the most likely start and extend while the next token is more likely
    /// inside than outside.
    static func forcedRun(_ logits: [Float], window: Int, start: Int, end: Int) -> ClosedRange<Int>? {
        guard start < end else { return nil }
        func probs(_ t: Int) -> (Float, Float, Float) {
            let o = logits[t], b = logits[window + t], i = logits[2 * window + t]
            let m = max(o, max(b, i))
            let eo = expf(o - m), eb = expf(b - m), ei = expf(i - m)
            let z = eo + eb + ei
            return (eo / z, eb / z, ei / z)
        }
        var best = start
        var bestP: Float = -1
        for t in start..<end {
            let p = probs(t).1
            if p > bestP { bestP = p; best = t }
        }
        guard bestP >= 0.15 else { return nil }
        var last = best
        while last + 1 < end {
            let (o, _, i) = probs(last + 1)
            if i > o { last += 1 } else { break }
        }
        return best...last
    }

    // MARK: - Numbers

    private static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: p, options: o)
    }

    /// Digit runs that are not quantities: dates, times, card and account
    /// fragments, long identifiers and phone numbers. A number field's
    /// pointer that lands inside one read "January 3, 2026" as 3.2026 and
    /// "Amex .... 3003" as 3003.
    static let notQuantities: [NSRegularExpression] = [
        rx(#"\b\d{1,2}[./-]\d{1,2}[./-]\d{2,4}\b"#),
        rx(#"\b\d{4}[./-]\d{1,2}[./-]\d{1,2}\b"#),
        rx(#"\b\d{1,2}(?:st|nd|rd|th)?\.?\s+(?:"# + RelativeDates.months + #")\.?,?\s+\d{4}\b"#, .caseInsensitive),
        rx(#"\b(?:"# + RelativeDates.months + #")\.?\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{4}\b"#, .caseInsensitive),
        rx(#"\b\d{1,2}:\d{2}\b"#),
        rx(#"(?:[*.•xX]{2,}\s*|ending in\s+|last four\s+)\d{4}\b"#, .caseInsensitive),
        rx(#"\+?\d[\d ()-]{8,}\d"#),
        rx(#"\b[A-Za-z]+[-/]?\d[\w-]*\b"#),
    ]

    /// Scalar ranges of every non-quantity digit run in `text`.
    static func nonQuantityRanges(_ text: String) -> [Range<Int>] {
        var out: [Range<Int>] = []
        let ns = NSRange(text.startIndex..., in: text)
        for r in notQuantities {
            for m in r.matches(in: text, range: ns) {
                guard let rr = Range(m.range, in: text) else { continue }
                let a = text.unicodeScalars.distance(from: text.unicodeScalars.startIndex,
                                                     to: rr.lowerBound)
                let b = a + text[rr].unicodeScalars.count
                out.append(a..<b)
            }
        }
        return out
    }

    /// Whether the scalar range [a, b) falls inside a non-quantity run.
    static func insideNonQuantity(_ a: Int, _ b: Int, _ ranges: [Range<Int>]) -> Bool {
        ranges.contains { $0.lowerBound <= a && b <= $0.upperBound && $0.count > (b - a) }
            || ranges.contains { $0.lowerBound <= a && b <= $0.upperBound
                                 && $0.count >= (b - a) && $0.count > 4 }
    }

    // MARK: - Dates written in the text

    /// Month name to number, across the supported languages; full names and
    /// the three-letter forms `Harness.monthsShort` already reads.
    static let monthNames: [String: Int] = {
        var m: [String: Int] = [:]
        let groups: [[String]] = [
            ["january", "januar", "enero", "janvier", "gennaio", "januari", "stycznia", "styczeń", "janeiro", "jan"],
            ["february", "februar", "febrero", "février", "febbraio", "februari", "lutego", "luty", "fevereiro", "feb"],
            ["march", "märz", "marzo", "mars", "maart", "marts", "marca", "marzec", "março", "mar"],
            ["april", "abril", "avril", "aprile", "kwietnia", "kwiecień", "apr"],
            ["may", "mai", "mayo", "maggio", "mei", "maj", "maja", "maio"],
            ["june", "juni", "junio", "juin", "giugno", "czerwca", "czerwiec", "junho", "jun"],
            ["july", "juli", "julio", "juillet", "luglio", "lipca", "lipiec", "julho", "jul"],
            ["august", "agosto", "août", "augustus", "sierpnia", "sierpień", "aug"],
            ["september", "septiembre", "septembre", "settembre", "września", "wrzesień", "setembro", "sep", "sept"],
            ["october", "oktober", "octubre", "octobre", "ottobre", "października", "październik", "outubro", "oct", "okt"],
            ["november", "noviembre", "novembre", "listopada", "listopad", "novembro", "nov"],
            ["december", "dezember", "diciembre", "décembre", "dicembre", "grudnia", "grudzień", "dezembro", "desember", "dec", "dez"],
        ]
        for (i, names) in groups.enumerated() { for n in names { m[n] = i + 1 } }
        return m
    }()

    struct TextDate: Hashable { let year: Int?; let month: Int; let day: Int }

    static let namePattern: String = monthNames.keys.sorted { $0.count > $1.count }
        .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    static let dayMonthYear = rx(#"\b(\d{1,2})(?:st|nd|rd|th|er|º|ª)?\.?\s*(?:de\s+|of\s+)?("#
        + namePattern + #")\.?,?\s*(?:de\s+|del\s+)?(\d{4})?\b"#, .caseInsensitive)
    static let monthDayYear = rx(#"\b("# + namePattern
        + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:,?\s*(\d{4})\b)?"#, .caseInsensitive)
    static let numericDate = rx(#"(?<![\d./-])(\d{1,2})[./-](\d{1,2})(?:[./-](\d{2,4}))?(?![\d./-]|\d)"#)
    static let isoDate = rx(#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#)
    static let cjkDate = rx(#"(?:(\d{4})\s*年\s*)?(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]"#)

    /// Whether the text reads month-first ("3/1/2026" as March 1). English
    /// and nothing else in the supported set does, so it is the one case
    /// that needs telling apart.
    static func monthFirst(_ text: String) -> Bool {
        let low = " " + text.lowercased() + " "
        let hits = [" the ", " and ", " for ", " with ", " your ", " you ", " is ", " to ", " of "]
            .filter { low.contains($0) }.count
        return hits >= 2
    }

    /// Every calendar date the text states outright.
    static func textDates(_ text: String) -> [TextDate] {
        var out: [TextDate] = []
        let ns = NSRange(text.startIndex..., in: text)
        func g(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            Range(m.range(at: i), in: text).map { String(text[$0]) }
        }
        func year(_ s: String?) -> Int? {
            guard let s, let y = Int(s) else { return nil }
            return y < 100 ? 2000 + y : y
        }
        func add(_ y: Int?, _ m: Int, _ d: Int) {
            guard (1...12).contains(m), (1...31).contains(d) else { return }
            out.append(TextDate(year: y, month: m, day: d))
        }
        for m in isoDate.matches(in: text, range: ns) {
            add(Int(g(m, 1)!), Int(g(m, 2)!)!, Int(g(m, 3)!)!)
        }
        for m in cjkDate.matches(in: text, range: ns) {
            add(year(g(m, 1)), Int(g(m, 2)!)!, Int(g(m, 3)!)!)
        }
        for m in dayMonthYear.matches(in: text, range: ns) {
            if let name = g(m, 2)?.lowercased(), let mo = monthNames[name] {
                add(year(g(m, 3)), mo, Int(g(m, 1)!)!)
            }
        }
        for m in monthDayYear.matches(in: text, range: ns) {
            if let name = g(m, 1)?.lowercased(), let mo = monthNames[name] {
                add(year(g(m, 3)), mo, Int(g(m, 2)!)!)
            }
        }
        let mf = monthFirst(text)
        for m in numericDate.matches(in: text, range: ns) {
            let a = Int(g(m, 1)!)!, b = Int(g(m, 2)!)!
            let y = year(g(m, 3))
            // Without a year, "3.5" is as likely a decimal as a date.
            if y == nil, let sep = Range(m.range, in: text).map({ text[$0] }),
               sep.contains(".") { continue }
            if a > 12 { add(y, b, a) }
            else if b > 12 { add(y, a, b) }
            else if mf { add(y, a, b) }
            else { add(y, b, a) }
        }
        return out
    }
}
