// The deterministic half of the product.
//
// The model's job is to LOCATE and CLASSIFY; converting what it points at
// into a typed value is ordinary code, and it is ordinary code on purpose.
// A parser that turns "950,000" / "9.5 million" / "950万" into 950000 is
// simply correct, where a learned digit decoder mis-scales. Keeping this out
// of the weights is also what makes the output valid by construction.
//
// Mirrors the Python reference in schemer-training/training/v60/. Where a
// rule is specified by a `harness/*.json` lever in the release bundle, that
// file is the contract and this is a port of it.

import Foundation

enum Harness {

    // MARK: - BIO span decoding

    /// Contiguous B/I runs over the text region, as token index ranges.
    /// Tags are O=0, B=1, I=2.
    static func bioRuns(tags: [Int], validCount: Int) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int? = nil
        for i in 0..<validCount {
            switch tags[i] {
            case 1:
                if let s = start { runs.append(s...(i - 1)) }
                start = i
            case 2:
                // An I with no open run is treated as O, exactly as
                // `BIOArrayHead.decode` does. Opening a run here instead
                // produced a stray item for every orphan I - "ried beans"
                // from "fried beans", "-15" from a seat range - and was the
                // entire array gap against the reference.
                break
            default:
                if let s = start { runs.append(s...(i - 1)); start = nil }
            }
        }
        if let s = start { runs.append(s...(validCount - 1)) }
        return runs
    }

    /// The run with the highest mean B/I probability.
    ///
    /// Not the longest. `_bio_best_span` in training/v60/score_heldout.py
    /// scores runs by mean tag confidence; picking by length systematically
    /// prefers a long low-confidence span over the short confident one the
    /// model meant.
    static func bestRun(_ logits: [Float], window: Int,
                        runs: [ClosedRange<Int>]) -> ClosedRange<Int>? {
        guard !runs.isEmpty else { return nil }
        func score(_ r: ClosedRange<Int>) -> Float {
            var total: Float = 0
            for t in r where t < window {
                let o = logits[0 * window + t], b = logits[1 * window + t]
                let i = logits[2 * window + t]
                let m = max(o, max(b, i))
                let eo = expf(o - m), eb = expf(b - m), ei = expf(i - m)
                total += max(eb, ei) / (eo + eb + ei)
            }
            return total / Float(max(1, r.count))
        }
        return runs.max { score($0) < score($1) }
    }

    /// Slice a token run back out of the source string using char offsets.
    /// Every returned string is a literal substring of the input, which is the
    /// property that makes extraction auditable.
    static func slice(_ text: String, tokens: [TokenSpan], run: ClosedRange<Int>) -> String? {
        let lo = max(0, run.lowerBound), hi = min(run.upperBound, tokens.count - 1)
        guard lo <= hi else { return nil }
        let spans = tokens[lo...hi].filter { $0.end > $0.start }
        guard let lo = spans.map(\.start).min(), let hi = spans.map(\.end).max(),
              lo < hi else { return nil }
        let scalars = Array(text.unicodeScalars)
        guard lo >= 0, hi <= scalars.count else { return nil }
        return trim(String(String.UnicodeScalarView(scalars[lo..<hi])))
    }

    /// Boundary cleanup. The model reads boundaries per token, and a token
    /// boundary is not always a word boundary: trailing punctuation and
    /// unbalanced brackets are the residue.
    static func trim(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = CharacterSet(charactersIn: "\"'“”‘’([{<,;:")
        let trail = CharacterSet(charactersIn: "\"'“”‘’)]}>,;:.!?")
        while let f = out.unicodeScalars.first, lead.contains(f) { out.removeFirst() }
        while let l = out.unicodeScalars.last, trail.contains(l) { out.removeLast() }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Span boundary cleanup

    /// Trailing function words, per language. A span that ends in one is a
    /// boundary error, not an answer.
    static let trailFunctionWords: Set<String> = [
        "at", "in", "on", "for", "to", "with", "the", "a", "an", "and", "of", "or",
        "um", "am", "im", "f\u{fc}r", "mit", "und", "der", "die", "das", "zu", "von",
        "en", "de", "para", "con", "y", "el", "la", "los", "las", "uma",
        "com", "e", "do", "da",
        "\u{e0}", "au", "aux", "pour", "avec", "et", "le", "les", "du", "des",
        "il", "lo", "gli", "per", "ed", "di", "dal", "alla",
        "het", "een", "van", "voor", "met", "op", "aan", "bij",
        "p\u{e5}", "til", "og", "av", "af", "hos", "fr\u{e5}n", "fra", "och", "att",
        "w", "na", "z", "dla", "i", "o", "przy",
    ]

    /// Japanese particles; Chinese is handled by the punctuation strip.
    static let trailParticles = Set("\u{306e}\u{306b}\u{3067}\u{3068}\u{3078}\u{304c}\u{3092}\u{306f}\u{3082}")

    private static let trailPunct = Set(" \t,.;:!?\u{3001}\u{3002}\u{00b7}-\u{2013}")

    /// Port of `_trim_span_tail`. Repeatedly strips trailing punctuation,
    /// function words and (when the schema has a datetime field) trailing
    /// temporal expressions, which are cross-field leakage rather than part
    /// of the string: "Meeting with Sarah tomorrow at 3pm" -> "Meeting with
    /// Sarah". Interior temporal words are never touched.
    static func trimSpanTail(_ input: String, temporalSiblings: Bool) -> String {
        var s = input
        var prev: String? = nil
        while !s.isEmpty, s != prev {
            prev = s
            while let last = s.last, trailPunct.contains(last) { s.removeLast() }
            let parts = s.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count >= 2 else {
                if let last = s.last, trailParticles.contains(last) { s.removeLast() }
                continue
            }
            let tail = String(parts[parts.count - 1]).lowercased()
            if trailFunctionWords.contains(tail) {
                s = parts.dropLast().joined(separator: " ")
            } else if temporalSiblings, temporalTail.contains(tail) {
                s = parts.dropLast().joined(separator: " ")
            } else if temporalSiblings,
                      temporalTail.contains(parts.suffix(2).joined(separator: " ")
                          .lowercased()) {
                s = parts.dropLast(2).joined(separator: " ")
            } else if let last = s.last, trailParticles.contains(last) {
                s.removeLast()
            }
        }
        return s
    }

    /// The temporal tail lexicon. A subset of the Python reference's
    /// relative-date lexicon: the words that actually appear at a span tail.
    static let temporalTail: Set<String> = [
        "today", "tomorrow", "yesterday", "tonight", "now",
        "heute", "morgen", "gestern", "hoy", "ma\u{f1}ana", "ayer",
        "aujourd'hui", "demain", "hier", "oggi", "domani", "ieri",
        "vandaag", "morgen", "gisteren", "i dag", "i morgen", "i g\u{e5}r",
        "idag", "imorgon", "ig\u{e5}r", "dzi\u{15b}", "jutro", "wczoraj",
        "hoje", "amanh\u{e3}", "ontem",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
        "sunday", "next", "last", "this",
    ]

    // MARK: - Format gates

    /// False only when the FIELD NAME clearly names a format and the value
    /// clearly violates it.
    ///
    /// The `describe` is deliberately not matched: a field that merely
    /// mentions a format ("recipient: who to email") is not that format, and
    /// matching describes rejected correct free-text answers. Unknown formats
    /// always pass.
    static func formatGateOK(field: String, value: String) -> Bool {
        let hint = field.lowercased()
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        func any(_ keys: [String]) -> Bool { keys.contains { hint.contains($0) } }

        if any(["email", "e-mail", "correo", "courriel"]) {
            let parts = v.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && !parts[0].isEmpty
                && parts[1].contains(".") && !v.contains(" ")
        }
        if any(["phone", "telefon", "tel\u{e9}fono", "t\u{e9}l\u{e9}phone",
                "telefoon", "mobil", "mobile", "\u{7535}\u{8bdd}", "\u{96fb}\u{8a71}"]) {
            let digits = v.filter(\.isNumber).count
            let allowed = CharacterSet(charactersIn: "+0123456789 -().\u{00a0}")
            return digits >= 6 && v.count >= 6 && v.count <= 20
                && v.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
        if any(["url", "website", "webseite", "sitio web", "site web", "link"]) {
            if v.contains(" ") { return false }
            let lower = v.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://")
                || lower.hasPrefix("www.") { return true }
            guard let dot = lower.lastIndex(of: "."), dot < lower.endIndex else {
                return false
            }
            let tld = lower[lower.index(after: dot)...].prefix { $0.isLetter }
            return tld.count >= 2
        }
        return true
    }

    // MARK: - Numbers

    private static let scaleWords: [(String, Double)] = [
        ("trillion", 1e12), ("billion", 1e9), ("million", 1e6), ("thousand", 1e3),
        ("mil", 1e6), ("兆", 1e12), ("億", 1e8), ("亿", 1e8), ("万", 1e4), ("萬", 1e4),
        ("k", 1e3), ("m", 1e6), ("b", 1e9),
    ]

    /// A numeric literal found in the text, with the scalar range it occupies.
    struct Grounded: Sendable {
        let value: Double
        let start: Int
        let end: Int
    }

    /// Every numeric literal in `text`, with offsets.
    ///
    /// The span head points at a token, and a token boundary is not a literal
    /// boundary: on "1.234,56" it selected ".234,56", which parses to 234.56
    /// and is off by 1000x. Snapping the pointer to a literal the text
    /// actually contains turns the head's job into SELECTION, which it can do,
    /// and leaves the arithmetic to code that is simply correct.
    ///
    /// Port of `grounded_values` in training/v60/number_grounding.py.
    static func groundedNumbers(_ text: String) -> [Grounded] {
        let s = Array(text.unicodeScalars)
        let isDigit: (Unicode.Scalar) -> Bool = { $0.value >= 48 && $0.value <= 57 }
        let isSep: (Unicode.Scalar) -> Bool = { $0 == "." || $0 == "," || $0 == " " || $0 == "\u{00a0}" }
        var out: [Grounded] = []
        var i = 0
        while i < s.count {
            guard isDigit(s[i]) else { i += 1; continue }
            var start = i
            // A sign immediately before the digits belongs to the literal.
            if start > 0, s[start - 1] == "-" || s[start - 1] == "+" { start -= 1 }
            var j = i
            while j < s.count {
                if isDigit(s[j]) { j += 1 }
                else if isSep(s[j]), j + 1 < s.count, isDigit(s[j + 1]) { j += 2 }
                else { break }
            }
            var end = j
            // A CJK myriad or a scale word directly after is part of the value.
            if j < s.count, "万萬亿億兆千百".unicodeScalars.contains(s[j]) { end = j + 1 }
            else {
                let tail = String(String.UnicodeScalarView(s[j..<min(s.count, j + 12)]))
                    .lowercased()
                for w in [" trillion", " billion", " million", " thousand", "k", "m", "b"]
                where tail.hasPrefix(w) {
                    end = j + w.unicodeScalars.count
                    break
                }
            }
            let lit = String(String.UnicodeScalarView(s[start..<end]))
            if let v = number(lit) { out.append(Grounded(value: v, start: start, end: end)) }
            i = max(j, i + 1)
        }
        return out
    }

    /// The literal overlapping `range` most, or the nearest one.
    static func snap(_ grounded: [Grounded], to range: Range<Int>) -> Grounded? {
        guard !grounded.isEmpty else { return nil }
        func overlap(_ g: Grounded) -> Int {
            max(0, min(g.end, range.upperBound) - max(g.start, range.lowerBound))
        }
        if let best = grounded.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0 {
            return best
        }
        return grounded.min {
            abs($0.start - range.lowerBound) < abs($1.start - range.lowerBound)
        }
    }

    /// Extend a located literal across space-separated thousand groups.
    ///
    /// Matches `(?:[\s\u{00a0}\u{2009}]\d{3})+(?!\d)` applied just past the
    /// span, and only when the span already ends in a digit.
    static func extendThousands(_ span: String, in text: String) -> String {
        guard let last = span.last, last.isNumber,
              let r = text.range(of: span) else { return span }
        var out = span
        var i = r.upperBound
        while i < text.endIndex {
            let sep = text[i]
            guard sep == " " || sep == "\u{00a0}" || sep == "\u{2009}" else { break }
            let after = text.index(after: i)
            let group = text[after...].prefix(3)
            guard group.count == 3, group.allSatisfy(\.isNumber) else { break }
            let next = text.index(after, offsetBy: 3, limitedBy: text.endIndex) ?? text.endIndex
            if next < text.endIndex, text[next].isNumber { break }
            out += String(sep) + group
            i = next
        }
        return out
    }

    /// Scale words, exactly `_SCALE` in training/v60/score_heldout.py.
    private static let referenceScale: [String: Double] = [
        "k": 1e3, "thousand": 1e3, "tys": 1e3, "mil": 1e6, "m": 1e6,
        "million": 1e6, "mln": 1e6, "b": 1e9, "billion": 1e9, "bn": 1e9,
        "\u{4e07}": 1e4, "\u{4ebf}": 1e8, "\u{5343}": 1e3,
    ]

    /// Port of `_parse_number_literal`, the reference's span parser.
    ///
    /// Differs from `number(_:)` in three ways that each changed answers:
    ///
    /// * it takes the FIRST numeric token in the span, not every digit in it;
    /// * a value outside [min, max] is REJECTED (returns nil), so the caller
    ///   falls through to the component decoder, which clamps. Accepting it
    ///   returned `weight_kg = 847362` against `max: 1000`;
    /// * a single separator is thousands only when EVERY group after it is
    ///   exactly three digits ("1,234,567"), not just the last.
    static func parseLiteral(_ span: String, min lo: Double?, max hi: Double?,
                             decimals: Int? = nil) -> Double? {
        let s = span.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        var scale = 1.0
        var tok: String? = nil

        // (\d[\d.,\s]*\d|\d)\s*(scale)\b
        let scalePattern = #"(\d[\d.,\s]*\d|\d)\s*(k|thousand|tys|mil|mln|million|m|b|bn|billion|\x{4e07}|\x{4ebf}|\x{5343})\b"#
        if let re = try? NSRegularExpression(pattern: scalePattern),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s) {
            tok = String(s[r1])
            scale = referenceScale[String(s[r2])] ?? 1
        } else if let re = try? NSRegularExpression(pattern: #"-?\d[\d.,\s]*\d|\d"#),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  let r = Range(m.range, in: s) {
            tok = String(s[r])
        }
        guard var t = tok?.replacingOccurrences(of: " ", with: "") else { return nil }
        t = t.filter { !$0.isWhitespace }

        let hasDot = t.contains("."), hasCom = t.contains(",")
        if hasDot && hasCom {
            let dec: Character = t.lastIndex(of: ".")! > t.lastIndex(of: ",")! ? "." : ","
            let thou: Character = dec == "." ? "," : "."
            t = String(t.filter { $0 != thou }.map { $0 == dec ? "." : $0 })
        } else if hasCom {
            let parts = t.split(separator: ",", omittingEmptySubsequences: false)
            t = parts.count > 1 && parts.dropFirst().allSatisfy({ $0.count == 3 })
                ? t.replacingOccurrences(of: ",", with: "")
                : t.replacingOccurrences(of: ",", with: ".")
        } else if hasDot {
            let parts = t.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count > 1 && parts.dropFirst().allSatisfy({ $0.count == 3 }) {
                t = t.replacingOccurrences(of: ".", with: "")
            }
        }
        guard let base = Double(t) else { return nil }
        let v = base * scale
        guard v >= (lo ?? -1e18), v <= (hi ?? 1e18) else { return nil }
        if let d = decimals {
            let f = pow(10.0, Double(d))
            return (v * f).rounded() / f
        }
        return v == v.rounded() ? v : (v * 1e4).rounded() / 1e4
    }

    /// Parse a located literal. Handles both thousands conventions, scale
    /// words, CJK myriads, currency symbols and percent signs.
    ///
    /// Returns nil when the span does not contain a number, which the caller
    /// treats as absence rather than guessing.
    static func number(_ raw: String) -> Double? {
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for sym in ["$", "€", "£", "¥", "₹", "%", "usd", "eur", "gbp", "jpy"] {
            s = s.replacingOccurrences(of: sym, with: "")
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        var scale = 1.0
        for (word, mult) in scaleWords where s.hasSuffix(word) {
            // A bare "k"/"m"/"b" only counts when digits precede it.
            let head = String(s.dropLast(word.count)).trimmingCharacters(in: .whitespaces)
            if head.rangeOfCharacter(from: .decimalDigits) != nil {
                scale = mult; s = head; break
            }
        }

        let digits = s.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" || $0 == "+" }
        guard digits.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
        guard let normalized = normalizeSeparators(digits) else { return nil }
        return normalized * scale
    }

    /// Decide which of `.` and `,` is the decimal mark. The last-seen
    /// separator wins when it has 1-2 trailing digits (1.234,56 vs 1,234.56);
    /// a separator with exactly 3 trailing digits is a thousands group.
    private static func normalizeSeparators(_ s: String) -> Double? {
        let lastDot = s.lastIndex(of: "."), lastComma = s.lastIndex(of: ",")
        var decimalMark: Character? = nil
        switch (lastDot, lastComma) {
        case (let d?, let c?):
            decimalMark = d > c ? "." : ","
        case (let d?, nil):
            decimalMark = s.distance(from: d, to: s.endIndex) - 1 == 3 && !s.hasPrefix("0.")
                ? nil : "."
        case (nil, let c?):
            decimalMark = s.distance(from: c, to: s.endIndex) - 1 == 3 ? nil : ","
        case (nil, nil):
            decimalMark = nil
        }
        var out = ""
        for ch in s {
            if ch == "." || ch == "," {
                if ch == decimalMark { out.append(".") }
            } else {
                out.append(ch)
            }
        }
        return Double(out)
    }

    /// `compose_from_logits`: assemble a value from the component decoder.
    ///
    /// `decimalPos` is how many integer digits the value has, so the shift is
    /// `decimalPos - 4` over the four significant-digit slots. Sign index 1
    /// means zero.
    static func composeNumber(sign: Int, magnitude: Int, digits: [Int],
                              decimalPos: Int) -> Value {
        if sign == 1 { return .number(0) }
        var sig = 0.0
        for (i, d) in digits.enumerated() {
            sig += Double(d) * pow(10.0, Double(digits.count - 1 - i))
        }
        let value = sig * pow(10.0, Double(decimalPos - digits.count))
        return .number(sign == 0 ? -value : value)
    }

    // MARK: - Datetime post-processing (ports from score_heldout.py)

    private static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: p, options: o)
    }

    /// `_ISO_TS`: a machine timestamp in the text.
    static let isoTimestamp = rx(#"\b(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?"#)

    /// `_ANY_DATE_YEAR`: any written year as part of a date, to tell a partial
    /// "Oct 12" from an absolute date.
    static let anyDateYear = rx(
        #"\b\d{1,2}[./-]\d{1,2}[./-]\d{4}\b|\b\d{4}-\d{1,2}-\d{1,2}\b"#
        + #"|\b[A-Za-zÀ-ÿ]{3,}\.?\s+\d{1,2},?\s+\d{4}\b|\b\d{1,2}\.?\s+[A-Za-zÀ-ÿ]{3,}\.?\s+\d{4}\b"#)

    /// `_MONTHS_SH`: first three letters of a month name, multilingual.
    static let monthsShort: [String: Int] = {
        let groups: [[String]] = [
            ["jan", "gen", "ene", "sty"], ["feb", "fev", "f\u{e9}v", "lut"],
            ["mar", "m\u{e4}r", "mrz", "maa"], ["apr", "avr", "abr", "kwi"],
            ["may", "mai", "mag", "mei", "maj"], ["jun", "giu", "jui", "cze"],
            ["jul", "lug", "jui", "lip"], ["aug", "ago", "ao\u{fb}", "aou", "sie"],
            ["sep", "set", "wrz"], ["oct", "okt", "ott", "pa\u{17a}", "paz", "out"],
            ["nov", "lis"], ["dec", "d\u{e9}c", "dez", "dic", "gru"],
        ]
        var m: [String: Int] = [:]
        // Later groups overwrite earlier ones, as the reference's dict build
        // does ("jui" ends up July).
        for (i, names) in groups.enumerated() { for n in names { m[n] = i + 1 } }
        return m
    }()

    /// `_year_of_matching_date`: the year of a text date whose month AND day
    /// match the composed date. Tying the year to the found month/day ignores
    /// distractor years elsewhere in a long document.
    static func yearOfMatchingDate(_ text: String, month cm: Int, day cd: Int) -> Int? {
        func all(_ p: String) -> [NSTextCheckingResult] {
            rx(p).matches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        func g(_ m: NSTextCheckingResult, _ i: Int) -> String {
            String(text[Range(m.range(at: i), in: text)!])
        }
        for m in all(#"\b(\d{1,2})[./-](\d{1,2})[./-](\d{4})\b"#) {
            let a = Int(g(m, 1))!, b = Int(g(m, 2))!
            if (b == cm && a == cd) || (a == cm && b == cd) { return Int(g(m, 3)) }
        }
        for m in all(#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#) {
            if Int(g(m, 2)) == cm, Int(g(m, 3)) == cd { return Int(g(m, 1)) }
        }
        for m in all(#"\b([A-Za-zÀ-ÿ]{3,})\.?\s+(\d{1,2}),?\s+(\d{4})\b"#) {
            if monthsShort[String(g(m, 1).lowercased().prefix(3))] == cm, Int(g(m, 2)) == cd {
                return Int(g(m, 3))
            }
        }
        for m in all(#"\b(\d{1,2})\.?\s+([A-Za-zÀ-ÿ]{3,})\.?\s+(\d{4})\b"#) {
            if monthsShort[String(g(m, 2).lowercased().prefix(3))] == cm, Int(g(m, 1)) == cd {
                return Int(g(m, 3))
            }
        }
        return nil
    }

    // MARK: - Datetime

    /// Compose the component classifier's argmaxes into ISO-8601.
    ///
    /// The model never learns date arithmetic: the runtime prepends
    /// `today=YYYY-MM-DD` to the joint input and the head reads absolute
    /// components off it. That is why there is no relative-date resolver here.
    static func datetime(year: Int, month: Int, day: Int,
                         hour: Int, minute: Int) -> String? {
        guard month >= 1, month <= 12, day >= 1, day <= 31,
              year >= 1, year <= 9999, hour >= 0, hour < 24,
              minute >= 0, minute < 60 else { return nil }
        // Reject a day the month does not have, the way datetime() does.
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= days[month - 1] else { return nil }
        return String(format: "%04d-%02d-%02dT%02d:%02d", year, month, day, hour, minute)
    }

    /// The year head is 256-way over an **offset from the anchor year**, not
    /// an absolute year: class 128 means "the anchor's year". That is what
    /// makes it schema- and era-independent, and it is why the runtime has to
    /// pass the anchor in rather than the head learning a calendar.
    ///
    /// `decode_year_offset` in training/v24/heads.py.
    static let yearOffsetRange = 128
    static func year(fromClass c: Int, anchorYear: Int) -> Int {
        anchorYear + (c - yearOffsetRange)
    }

    // MARK: - Small numeric helpers

    static func argmax(_ xs: ArraySlice<Float>) -> Int {
        var best = xs.startIndex
        for i in xs.indices where xs[i] > xs[best] { best = i }
        return best - xs.startIndex
    }

    static func softmax2(_ a: Float, _ b: Float) -> Float {
        let m = max(a, b)
        let ea = expf(a - m), eb = expf(b - m)
        return eb / (ea + eb)
    }
}
