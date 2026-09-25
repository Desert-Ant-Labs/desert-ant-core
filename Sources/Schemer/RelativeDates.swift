// Deterministic multilingual relative-date resolution.
//
// Port of schemer-training/training/v60/relative_dates.py. The datetime head
// composes times reliably but systematically fails day-offset arithmetic
// ("tomorrow" / "morgen" / "mañana" all collapse to the anchor date), so the
// harness resolves relative-day expressions itself: a lexicon plus date math.
//
// Conservative by contract: a date comes back only when the text holds
// exactly one unambiguous relative-day expression AND no absolute date.
// Anything else returns nil and the model's composed value stands. The caller
// replaces only the DATE; time of day stays with the model.
//
// Positions are Unicode SCALAR offsets, matching Python's `str` indexing, so
// the nearest-marker tie-break measures the same distances the reference does.

import Foundation

enum RelativeDates {

    // MARK: - Lexicon

    /// Day-offset phrases, longest first. Longest-first is a correctness
    /// invariant: a shorter phrase inside a longer one would register both
    /// offsets and read as ambiguous.
    static let offsetPhrases: [(String, Int)] = {
        var p: [(String, Int)] = [
            ("day after tomorrow", 2), ("\u{fc}bermorgen", 2), ("ubermorgen", 2),
            ("pasado ma\u{f1}ana", 2), ("apr\u{e8}s-demain", 2), ("apres-demain", 2),
            ("dopodomani", 2), ("overmorgen", 2), ("i overmorgen", 2),
            ("i \u{f6}vermorgon", 2), ("i overmorgon", 2), ("pojutrze", 2),
            ("depois de amanh\u{e3}", 2), ("\u{660e}\u{5f8c}\u{65e5}", 2),
            ("\u{3042}\u{3055}\u{3063}\u{3066}", 2), ("\u{540e}\u{5929}", 2),
            ("\u{5f8c}\u{5929}", 2),
            ("tomorrow", 1), ("morgen", 1), ("ma\u{f1}ana", 1), ("demain", 1),
            ("domani", 1), ("i morgen", 1), ("i morgon", 1), ("imorgon", 1),
            ("jutro", 1), ("amanh\u{e3}", 1), ("\u{660e}\u{65e5}", 1),
            ("\u{3042}\u{3057}\u{305f}", 1), ("\u{660e}\u{5929}", 1),
            ("today", 0), ("heute", 0), ("hoy", 0), ("aujourd'hui", 0),
            ("oggi", 0), ("vandaag", 0), ("i dag", 0), ("idag", 0),
            ("dzi\u{15b}", 0), ("dzisiaj", 0), ("hoje", 0), ("\u{4eca}\u{65e5}", 0),
            ("\u{4eca}\u{5929}", 0),
            ("yesterday", -1), ("gestern", -1), ("ayer", -1), ("hier soir", -1),
            ("ieri", -1), ("gisteren", -1), ("i g\u{e5}r", -1), ("ig\u{e5}r", -1),
            ("wczoraj", -1), ("ontem", -1), ("\u{6628}\u{65e5}", -1),
            ("\u{6628}\u{5929}", -1),
            // Curated typos and unaccented ASCII variants. CURATED, never
            // fuzzy: edit distance would turn the name "Morgan" into "morgen".
            ("tomorow", 1), ("tommorow", 1), ("tommorrow", 1), ("tomarrow", 1),
            ("yestarday", -1), ("yesteday", -1), ("yesterdy", -1),
            ("manana", 1), ("pasado manana", 2),
            ("aujourdhui", 0), ("aujourd hui", 0), ("apres demain", 2),
            ("i gar", -1), ("igar", -1),
            ("depois de amanha", 2), ("amanha", 1), ("dzis", 0),
        ]
        // Stable sort, longest first - Python's list.sort is stable too, so
        // equal-length phrases keep their declared order.
        p = p.enumerated().sorted {
            let a = $0.element.0.unicodeScalars.count, b = $1.element.0.unicodeScalars.count
            return a != b ? a > b : $0.offset < $1.offset
        }.map(\.element)
        return p
    }()

    static let wordNums: [String: Int] = [
        "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10,
        "zwei": 2, "drei": 3, "vier": 4, "f\u{fc}nf": 5,
        "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5,
        "deux": 2, "trois": 3, "quatre": 4, "cinq": 5,
        "due": 2, "tre": 3, "quattro": 4,
        "twee": 2, "drie": 3,
        "to": 2, "fire": 4, "fem": 5,
        "tv\u{e5}": 2, "dwa": 2, "trzy": 3, "duas": 2, "dois": 2, "tr\u{ea}s": 3,
    ]

    static let oneWords = "a|an|una|une|un|en|ein|einer|ett|uma|um"
    static let dayUnits = "days?|tagen?|d\u{ed}as?|jours?|giorni|dagen|dage|dager|dagar|dni|dias?|\u{65e5}|\u{5929}"
    static let weekUnits = "weeks?|wochen?|semanas?|semaines?|settimane?|weken|uger?|uker?|veckor?|tygodni\\w*|\u{9031}\u{9593}|\u{5468}"

    static let weekdays: [String: Int] = [
        "monday": 0, "montag": 0, "lunes": 0, "lundi": 0, "luned\u{ec}": 0,
        "maandag": 0, "mandag": 0, "m\u{e5}ndag": 0, "poniedzia\u{142}ek": 0,
        "segunda-feira": 0, "\u{6708}\u{66dc}\u{65e5}": 0, "\u{5468}\u{4e00}": 0,
        "tuesday": 1, "dienstag": 1, "martes": 1, "mardi": 1, "marted\u{ec}": 1,
        "dinsdag": 1, "tirsdag": 1, "tisdag": 1, "wtorek": 1,
        "ter\u{e7}a-feira": 1, "\u{706b}\u{66dc}\u{65e5}": 1, "\u{5468}\u{4e8c}": 1,
        "wednesday": 2, "mittwoch": 2, "mi\u{e9}rcoles": 2, "mercredi": 2,
        "mercoled\u{ec}": 2, "woensdag": 2, "onsdag": 2, "\u{15b}roda": 2,
        "quarta-feira": 2, "\u{6c34}\u{66dc}\u{65e5}": 2, "\u{5468}\u{4e09}": 2,
        "thursday": 3, "donnerstag": 3, "jueves": 3, "jeudi": 3, "gioved\u{ec}": 3,
        "donderdag": 3, "torsdag": 3, "czwartek": 3, "quinta-feira": 3,
        "\u{6728}\u{66dc}\u{65e5}": 3, "\u{5468}\u{56db}": 3,
        "friday": 4, "freitag": 4, "viernes": 4, "vendredi": 4, "venerd\u{ec}": 4,
        "vrijdag": 4, "fredag": 4, "pi\u{105}tek": 4, "sexta-feira": 4,
        "\u{91d1}\u{66dc}\u{65e5}": 4, "\u{5468}\u{4e94}": 4,
        "saturday": 5, "samstag": 5, "s\u{e1}bado": 5, "samedi": 5, "sabato": 5,
        "zaterdag": 5, "l\u{f8}rdag": 5, "l\u{f6}rdag": 5, "sobota": 5,
        "\u{571f}\u{66dc}\u{65e5}": 5, "\u{5468}\u{516d}": 5,
        "sunday": 6, "sonntag": 6, "domingo": 6, "dimanche": 6, "domenica": 6,
        "zondag": 6, "s\u{f8}ndag": 6, "s\u{f6}ndag": 6, "niedziela": 6,
        "\u{65e5}\u{66dc}\u{65e5}": 6, "\u{5468}\u{65e5}": 6,
    ]

    static let nextWords = [
        "next", "n\u{e4}chsten", "n\u{e4}chster", "pr\u{f3}ximo", "pr\u{f3}xima",
        "prochain", "prochaine", "prossimo", "prossima", "volgende",
        "neste", "n\u{e6}ste", "n\u{e4}sta", "przysz\u{142}y", "przysz\u{142}a",
        "\u{6765}\u{9031}\u{306e}", "\u{4e0b}",
    ]

    static let months = "january|february|march|april|may|june|july|august|september|october|november|december|januar|februar|m\u{e4}rz|mai|juni|juli|oktober|dezember|enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|octubre|noviembre|diciembre|janvier|f\u{e9}vrier|mars|avril|juin|juillet|ao\u{fb}t|septembre|octobre|novembre|d\u{e9}cembre|gennaio|febbraio|aprile|maggio|giugno|luglio|settembre|ottobre|dicembre|januari|februari|maart|mei|augustus|josember|marts|maj|oktober|stycze\u{144}|stycznia|luty|lutego|marzec|marca|kwiecie\u{144}|kwietnia|czerwca|lipca|sierpnia|wrze\u{15b}nia|pa\u{17a}dziernika|listopada|grudnia|janeiro|fevereiro|mar\u{e7}o|maio|junho|julho|setembro|outubro|novembro|dezembro|desember|februar|mars|april|juni|juli|august|september|november"

    // MARK: - Compiled patterns

    private static func re(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: p, options: opts)
    }

    static let absoluteDate = re(
        #"\b\d{4}\b|\b\d{1,2}[./-]\d{1,2}[./-]\d{2,4}\b|"#
        + #"\b\d{1,2}\.?\s*(?:"# + months + #")\b|"#
        + #"\b(?:"# + months + #")\s+\d{1,2}\b|"#
        + "\\d{1,2}\u{6708}\\d{1,2}\u{65e5}", .caseInsensitive)

    static let inNDays = re(
        #"\b(?:in|om|dans|en|entre|za|w ciągu|daqui a|fra|tra)\s+("#
        + #"\d{1,2}|"# + wordNums.keys.joined(separator: "|") + "|" + oneWords
        + #")\s+("# + dayUnits + "|" + weekUnits + #")\b"#, .caseInsensitive)

    static let weekUnitRe = re("^(?:" + weekUnits + ")$", .caseInsensitive)
    static let oneWordRe = re("^(?:" + oneWords + ")$", .caseInsensitive)

    static let nextWeekday = re(
        #"\b("# + nextWords.joined(separator: "|") + #")\s*("#
        + weekdays.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        + #")\b"#, .caseInsensitive)

    static let lastWords = re(
        #"\b(last|past|previous|letzten?|vergangenen?|förra|sidste|forrige|"#
        + #"ostatni\w*|pasado|dernier|scorso|vorige|afgelopen)\s*$"#, .caseInsensitive)

    static let timePatterns: [NSRegularExpression] = [
        re(#"\b(\d{1,2}):(\d{2})\b"#),
        re(#"\b(\d{1,2})\s*(am|pm)\b"#, .caseInsensitive),
        re(#"\b(\d{1,2})(?::(\d{2}))?\s*uhr\b"#, .caseInsensitive),
        re(#"\b(?:klockan|klokka|kl\.?)\s*(\d{1,2})(?::(\d{2}))?\b"#, .caseInsensitive),
        re(#"\ba las?\s+(\d{1,2})(?::(\d{2}))?\b"#, .caseInsensitive),
        re(#"\balle\s+(\d{1,2})(?::(\d{2}))?\b"#, .caseInsensitive),
        re(#"\bà\s+(\d{1,2})\s*h\s*(\d{2})?\b"#, .caseInsensitive),
        re(#"\bo\s+(\d{1,2}):(\d{2})\b"#, .caseInsensitive),
        re("(\\d{1,2})\u{6642}(?:(\\d{1,2})\u{5206})?"),
        re("(\\d{1,2})\u{70b9}"),
        re(#"\b(noon|midnight)\b"#, .caseInsensitive),
    ]

    // MARK: - Helpers over scalar offsets

    /// NSRegularExpression works in UTF-16; the reference measures distances
    /// in code points. Convert every match position before comparing.
    private static func scalarOffset(_ s: String, utf16 u: Int) -> Int {
        let idx = String.Index(utf16Offset: u, in: s)
        return s.unicodeScalars.distance(from: s.unicodeScalars.startIndex, to: idx)
    }

    private static func matches(_ r: NSRegularExpression, _ s: String) -> [NSTextCheckingResult] {
        r.matches(in: s, range: NSRange(s.startIndex..., in: s))
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String? {
        guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: s) else { return nil }
        return String(s[r])
    }

    private static func isAlpha(_ c: Unicode.Scalar) -> Bool {
        c.properties.isAlphabetic
    }

    /// `_phrase_matches`: word-bounded phrase hits, skipping any covered by a
    /// longer phrase already matched. Offsets in scalars.
    static func phraseMatches(_ low: String) -> [(Int, Int, Int)] {
        let s = Array(low.unicodeScalars)
        var out: [(Int, Int, Int)] = []
        for (phrase, off) in offsetPhrases {
            let p = Array(phrase.unicodeScalars)
            guard !p.isEmpty, p.count <= s.count else { continue }
            var start = 0
            while start + p.count <= s.count {
                var found = -1
                var i = start
                while i + p.count <= s.count {
                    if s[i] == p[0], Array(s[i..<(i + p.count)]) == p { found = i; break }
                    i += 1
                }
                if found < 0 { break }
                let j = found + p.count
                let beforeOK = found == 0 || !isAlpha(s[found - 1])
                let afterOK = j >= s.count || !isAlpha(s[j])
                if beforeOK, afterOK,
                   !out.contains(where: { $0.0 <= found && j <= $0.1 }) {
                    out.append((found, j, off))
                }
                start = j
            }
        }
        return out
    }

    // MARK: - Public

    private static let pmWords = ["午後", "下午", "晚上", "傍晚", "오후", "저녁"]
    private static let amWords = ["午前", "上午", "早上", "凌晨", "오전", "아침"]

    private enum TimeForm { case ampm, hm, cjk, word }

    /// `_SOLE_TIME_PATTERNS`: forms that fix a time of day on their own.
    private static let soleTimePatterns: [(NSRegularExpression, TimeForm)] = {
        func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
            // swiftlint:disable:next force_try
            try! NSRegularExpression(pattern: p, options: o)
        }
        let pm = "(?:" + pmWords.joined(separator: "|") + #")\s*"#
        let am = "(?:" + amWords.joined(separator: "|") + #")\s*"#
        return [
            (rx(#"(?<![\d:.])(\d{1,2})(?::(\d{2}))?\s*([ap])\.?m\b\.?"#, .caseInsensitive), .ampm),
            (rx(#"(?<![\d:.])(\d{1,2}):(\d{2})(?![\d:]|\s*[ap]\.?m\b)"#, .caseInsensitive), .hm),
            (rx(#"(?<![\d:.])(\d{1,2})(?:[:.](\d{2}))?\s*uhr\b"#, .caseInsensitive), .hm),
            (rx(#"\b(?:klockan|klokka|kl\.?)\s*(\d{1,2})(?:[:.](\d{2}))?\b"#, .caseInsensitive), .hm),
            (rx(#"\bà\s+(\d{1,2})\s*h\s*(\d{2})?"#, .caseInsensitive), .hm),
            (rx("(" + pm + "|" + am + #")?(\d{1,2})\s*[時点시]\s*(?:(\d{1,2})\s*[分분]|(半))?"#), .cjk),
            (rx(#"\b(noon|midnight|midi|minuit|mediodía|medianoche|mezzogiorno|mezzanotte)\b"#,
                .caseInsensitive), .word),
        ]
    }()

    private static let wordTimes: [String: (Int, Int)] = [
        "noon": (12, 0), "midi": (12, 0), "mediodía": (12, 0), "mezzogiorno": (12, 0),
        "midnight": (0, 0), "minuit": (0, 0), "medianoche": (0, 0), "mezzanotte": (0, 0),
    ]

    /// Python `int()` of a `\d+` match, which reads any script's digits.
    private static func number(_ s: String?) -> Int? {
        guard let s, !s.isEmpty else { return nil }
        var n = 0
        for c in s.unicodeScalars {
            guard let v = c.properties.numericType == .decimal ? c.properties.numericValue : nil
            else { return nil }
            n = n * 10 + Int(v)
        }
        return n
    }

    /// `sole_time_of_day`: (hour, minute) when the text states exactly one
    /// distinct time of day in a form that fixes it (am/pm, HH:MM, 14 Uhr,
    /// 14時30分, noon...), else nil. The datetime head's hour drifts ("on
    /// Tuesday at 11pm" read as 18:00), so a time the text states outright
    /// wins over it.
    static func soleTimeOfDay(_ text: String) -> (Int, Int)? {
        var seen: [(Int, Int)] = []
        for (pat, form) in soleTimePatterns {
            for m in matches(pat, text) {
                var h: Int, mi: Int
                switch form {
                case .word:
                    guard let t = group(m, 1, text).flatMap({ wordTimes[$0.lowercased()] }) else { continue }
                    (h, mi) = t
                case .cjk:
                    guard let hv = number(group(m, 2, text)) else { continue }
                    h = hv
                    mi = group(m, 4, text) != nil ? 30 : (number(group(m, 3, text)) ?? 0)
                    if let marker = group(m, 1, text), pmWords.contains(where: marker.hasPrefix), h < 12 {
                        h += 12
                    }
                case .hm, .ampm:
                    guard let hv = number(group(m, 1, text)) else { continue }
                    h = hv
                    mi = number(group(m, 2, text)) ?? 0
                    if form == .ampm {
                        guard (1...12).contains(h) else { continue }
                        h = h % 12 + (group(m, 3, text)?.lowercased() == "p" ? 12 : 0)
                    }
                }
                guard (0...23).contains(h), (0...59).contains(mi) else { continue }
                if !seen.contains(where: { $0 == (h, mi) }) { seen.append((h, mi)) }
            }
        }
        return seen.count == 1 ? seen[0] : nil
    }

    /// `parse_time_of_day`: (hour, minute, scalar position) of the earliest
    /// strong time expression, or nil. Bare numbers never match.
    static func timeOfDay(_ text: String) -> (Int, Int, Int)? {
        var best: (Int, Int, Int)? = nil
        for pat in timePatterns {
            guard let m = pat.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
            else { continue }
            let g1 = group(m, 1, text)
            var h: Int, mi: Int
            if let g = g1?.lowercased(), g == "noon" || g == "midnight" {
                (h, mi) = g == "noon" ? (12, 0) : (0, 0)
            } else {
                guard let g = g1, let hv = Int(g) else { continue }
                h = hv
                let g2 = group(m, 2, text)
                if let ap = g2?.lowercased(), ap == "am" || ap == "pm" {
                    mi = 0
                    if ap == "pm", h != 12 { h += 12 }
                    if ap == "am", h == 12 { h = 0 }
                } else {
                    mi = g2.flatMap(Int.init) ?? 0
                }
            }
            guard (0...23).contains(h), (0...59).contains(mi) else { continue }
            let pos = scalarOffset(text, utf16: m.range.location)
            if best == nil || pos < best!.2 { best = (h, mi, pos) }
        }
        return best
    }

    /// `resolve_relative_date`: the relative-day expression resolved against
    /// `anchor`, or nil when absent, ambiguous, or an absolute date is present.
    static func resolve(_ text: String, anchor: DateComponents) -> DateComponents? {
        if absoluteDate.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
            return nil
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let base = cal.date(from: anchor) else { return nil }
        func plus(_ d: Int) -> DateComponents {
            cal.dateComponents([.year, .month, .day],
                               from: cal.date(byAdding: .day, value: d, to: base)!)
        }
        // Python weekday(): Monday = 0. Calendar: Sunday = 1.
        let anchorWD = (cal.component(.weekday, from: base) + 5) % 7

        let low = text.lowercased()
        var cands: [(Int, Int, DateComponents)] = []
        for (s, e, off) in phraseMatches(low) { cands.append((s, e, plus(off))) }

        for m in matches(inNDays, text) {
            guard let tok = group(m, 1, text)?.lowercased() else { continue }
            var n: Int?
            if let v = Int(tok) { n = v }
            else if oneWordRe.firstMatch(in: tok, range: NSRange(tok.startIndex..., in: tok)) != nil { n = 1 }
            else { n = wordNums[tok] }
            guard var days = n, days != 0 else { continue }
            if let unit = group(m, 2, text),
               weekUnitRe.firstMatch(in: unit, range: NSRange(unit.startIndex..., in: unit)) != nil {
                days *= 7
            }
            cands.append((scalarOffset(text, utf16: m.range.location),
                          scalarOffset(text, utf16: m.range.location + m.range.length),
                          plus(days)))
        }

        for m in matches(nextWeekday, text) {
            guard let name = group(m, 2, text)?.lowercased(), let wd = weekdays[name]
            else { continue }
            let delta = ((wd - anchorWD - 1) % 7 + 7) % 7 + 1     // strictly after
            cands.append((scalarOffset(text, utf16: m.range.location),
                          scalarOffset(text, utf16: m.range.location + m.range.length),
                          plus(delta)))
        }

        if cands.isEmpty {
            // Bare weekday ("lunch on Friday"): next occurrence, only as the
            // sole marker and not preceded by a 'last'-word.
            var hits: [(Int, Int, Int)] = []
            for (name, wd) in weekdays {
                let r = re("(?<![\\w])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\w])")
                for m in matches(r, low) {
                    let prefix = String(low[..<Range(m.range, in: low)!.lowerBound])
                    if lastWords.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) != nil {
                        continue
                    }
                    hits.append((scalarOffset(low, utf16: m.range.location),
                                 scalarOffset(low, utf16: m.range.location + m.range.length), wd))
                }
            }
            if Set(hits.map(\.2)).count == 1, let h = hits.first {
                let delta = ((h.2 - anchorWD - 1) % 7 + 7) % 7 + 1
                cands.append((h.0, h.1, plus(delta)))
            }
        }

        func key(_ c: DateComponents) -> Int { c.year! * 10_000 + c.month! * 100 + c.day! }
        let uniq = Set(cands.map { key($0.2) })
        if uniq.count == 1 { return cands[0].2 }
        if uniq.count > 1, let t = timeOfDay(text), cands.count >= 2 {
            let tpos = t.2
            func dist(_ c: (Int, Int, DateComponents)) -> Int { min(abs(tpos - c.1), abs(c.0 - tpos)) }
            let scored = cands.sorted { dist($0) < dist($1) }
            let n = dist(scored[0]), r = dist(scored[1])
            if n <= 25, r - n >= 10 { return scored[0].2 }
        }
        return nil
    }
}
