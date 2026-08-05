import DesertAnt

/// Portable span post-processing - a direct port of `redact_training.pipeline`
/// (and the demo's `pipeline.mjs`): BIOES decoding, word snapping, name
/// bridging, address/state/unit recognizers, and the deterministic-owner merge.
enum Pipeline {
    static let nameFamilies: Set<String> = ["GIVEN_NAME", "SURNAME"]
    private static let detOwned: Set<String> = ["SSN", "CREDIT_CARD", "EMAIL", "URL", "IP_ADDRESS", "BANK_ACCOUNT", "ROUTING_NUMBER"]
    private static let connect: Set<Unicode.Scalar> = ["-", "'", "\u{2019}"]

    private static let particles: Set<String> = [
        "de", "del", "della", "dell", "di", "da", "das", "dos", "du", "van", "von",
        "der", "den", "ter", "la", "le", "el", "al", "bin", "ibn", "mac", "mc",
        "o", "st", "of", "y", "e",
    ]
    private static let allParticles: Set<String> = [
        "van", "von", "de", "del", "della", "dell", "di", "da", "das", "dos", "du",
        "zu", "af", "ter", "ten", "des", "do", "der", "den", "la", "le", "el", "y",
    ]
    private static let usStates: Set<String> = Set(
        ("AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS "
       + "MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY").split(separator: " ").map(String.init))

    private static let usStreetRE = rx(
        #"\b(\d{1,6}[A-Za-z]?)\s+((?:[A-Z][A-Za-z0-9.'’-]*\s+){0,4}(?:Street|Avenue|Boulevard|Road|Lane|Drive|Court|Place|Terrace|Circle|Highway|Parkway|Square|Trail|Crescent|Alley|Loop|Way|St|Ave|Blvd|Rd|Ln|Dr|Ct|Pl|Ter|Cir|Hwy|Pkwy|Sq|Trl|Aly))\b\.?(?=$|[\s,.;:)])"#)
    private static let stateZipRE = rx(#"(?:,\s*|\s)([A-Z]{2})\s+(\d{5}(?:-\d{4})?)\b"#)
    /// True when the text is ALL-CAPS.
    static func isShouting(_ text: String) -> Bool {
        var letters = 0
        for ch in text where ch.isLetter {
            if !ch.isUppercase { return false }
            letters += 1
        }
        return letters > 1
    }

    /// Title-case `text`, or nil if any character does not map 1:1.
    /// (`ß` uppercases to `SS`, which would shift every later span.)
    static func titleCase(_ text: String) -> String? {
        var out = ""
        out.reserveCapacity(text.count)
        var atWordStart = true
        for ch in text {
            if ch.isLetter {
                let mapped = atWordStart ? ch.uppercased() : ch.lowercased()
                if mapped.count != 1 { return nil }
                out += mapped
                atWordStart = false
            } else {
                out.append(ch)
                atWordStart = true
            }
        }
        return out
    }

    /// Title-case ALL-CAPS input before the model sees it: the trimmed vocab
    /// shreds uppercase (Cyrillic goes character-by-character), which cost 18pt
    /// of name recall. Offsets are unchanged, so spans stay valid.
    static func modelInput(for text: String) -> String {
        guard isShouting(text), let normalised = titleCase(text),
              normalised.utf16.count == text.utf16.count else { return text }
        return normalised
    }

    /// False when every word is capitalised, so capitalisation cannot mark a
    /// name. Gates the name-run heuristics: `modelInput(for:)` title-cases
    /// shouted text and would otherwise manufacture the signal they key on.
    static func casingIsInformative(_ text: String) -> Bool {
        var words: [String] = []
        var current = ""
        var sawLower = false
        for ch in text {
            if ch.isLetter || ch == "'" || ch == "-" || ch == "\u{2019}" {
                current.append(ch)
                if ch.isLowercase { sawLower = true }
            } else {
                if let f = current.first, f.isLetter { words.append(current) }
                current = ""
            }
        }
        if let f = current.first, f.isLetter { words.append(current) }
        if words.count < 3 { return true }
        if !sawLower { return false }
        return !words.allSatisfy { $0.first?.isUppercase == true }
    }

    // The separator is mandatory: without it `unit4` matched as a unit number.
    private static let secAddrRE = rx(#"\b(?:Apartment|Apt|Suite|Ste|Unit|Building|Bldg|Floor|Fl|Room|Rm|Department|Dept|Trailer|Trlr|Space|Spc|Lot)(?:\.|\s|#)\s*#?\s*(?:\d{1,4}[A-Za-z]?|[A-Za-z]\d{1,4})\b"#, ci: true)
    private static let bnumAfterRE = rx(#"^[\s,]{0,2}(\d{1,5}[a-zA-Z]?(?:[-/]\d{1,4}[a-zA-Z]?)?)\b"#)
    private static let bnumBeforeRE = rx(#"(\d{1,5}[a-zA-Z]?)[\s,]{0,2}$"#)
    private static let nextTokenRE = rx(#"^(\s+)([^\s,.;:!?)\]}"]+)"#)
    private static let badGapRE = rx("[,;:/&|()\\[\\]{}\"<>\\n\\t]")

    // MARK: helpers
    private static func isUpperLike(_ c: Character) -> Bool { String(c) == String(c).uppercased() }
    /// Trim characters from both ends (portable stand-in for CharacterSet trimming).
    static func trim(_ s: String, _ set: Set<Character>) -> String {
        var chars = Array(s)
        while let f = chars.first, set.contains(f) { chars.removeFirst() }
        while let l = chars.last, set.contains(l) { chars.removeLast() }
        return String(chars)
    }
    private static let edgeTrim: Set<Character> = [".", "'", "\u{2019}", "-"]
    private static func trimEdges(_ s: String) -> String { trim(s, edgeTrim) }

    // MARK: BIOES → spans
    static func bioesToSpans(_ tags: [String], _ offsets: [(Int, Int)]) -> [Span] {
        var out: [Span] = []
        var label: String? = nil, start: Int? = nil, end: Int? = nil
        func close() {
            if let l = label, let s = start, let e = end, e > s { out.append(Span(s, e, l)) }
            label = nil; start = nil; end = nil
        }
        for i in 0..<tags.count {
            let (a, b) = offsets[i]
            if b <= a { continue }
            let tag = tags[i]
            if tag == "O" { close(); continue }
            guard let dash = tag.firstIndex(of: "-") else { close(); continue }
            let prefix = String(tag[..<dash])
            let lab = String(tag[tag.index(after: dash)...])
            switch prefix {
            case "S": close(); out.append(Span(a, b, lab))
            case "B": close(); label = lab; start = a; end = b
            case "I":
                if label == lab { end = b } else { close(); label = lab; start = a; end = b }
            case "E":
                if label == lab { end = b; close() } else { close(); out.append(Span(a, b, lab)) }
            default: close()
            }
        }
        close()
        return out
    }

    // MARK: merges
    static func mergeSameLabel(_ spans: [Span]) -> [Span] {
        let ordered = spans.sorted {
            $0.start != $1.start ? $0.start < $1.start
                : ($0.end - $0.start) != ($1.end - $1.start) ? ($0.end - $0.start) > ($1.end - $1.start)
                : $0.label < $1.label
        }
        var out: [Span] = []
        for s in ordered {
            if let last = out.last, s.label == last.label, s.start <= last.end {
                out[out.count - 1].end = max(last.end, s.end)
            } else if out.isEmpty || s.start >= out[out.count - 1].end {
                out.append(s)
            }
        }
        return out
    }

    static func mergePriority(_ spans: [Span]) -> [Span] {
        func prio(_ s: Span) -> (Int, Int) { (detOwned.contains(s.label) ? 2 : 1, s.end - s.start) }
        func gt(_ a: (Int, Int), _ b: (Int, Int)) -> Bool { a.0 > b.0 || (a.0 == b.0 && a.1 > b.1) }
        let ordered = spans.sorted {
            $0.start != $1.start ? $0.start < $1.start
                : ($0.end - $0.start) != ($1.end - $1.start) ? ($0.end - $0.start) > ($1.end - $1.start)
                : $0.label < $1.label
        }
        var out: [Span] = []
        for s in ordered {
            if let last = out.last, s.label == last.label, s.start <= last.end {
                out[out.count - 1].end = max(last.end, s.end)
            } else if out.isEmpty || s.start >= out[out.count - 1].end {
                out.append(s)
            } else if gt(prio(s), prio(out[out.count - 1])) {
                out[out.count - 1] = s
            }
        }
        return out
    }

    // MARK: snapping
    private static func snapOne(_ t: UTF16Text, _ start: Int, _ end: Int) -> (Int, Int) {
        let n = t.length
        var s = max(0, min(start, n)), e = max(0, min(end, n))
        while s > 0 {
            if t.isWordChar(at: s - 1) { s -= 1 }
            else if let c = t.scalar(at: s - 1), connect.contains(c), s - 2 >= 0, t.isWordChar(at: s - 2) { s -= 1 }
            else { break }
        }
        while e < n {
            if t.isWordChar(at: e) { e += 1 }
            else if let c = t.scalar(at: e), connect.contains(c), e + 1 < n, t.isWordChar(at: e + 1) { e += 1 }
            else { break }
        }
        return (s, e)
    }

    static func snapSpans(_ t: UTF16Text, _ spans: [Span]) -> [Span] {
        mergeSameLabel(spans.map { sp in
            let (s, e) = snapOne(t, sp.start, sp.end)
            return Span(s, e, sp.label, sp.score)
        })
    }

    // MARK: name gaps / particles
    private static func gapIsNameLike(_ gap: String) -> Bool {
        if gap.allSatisfy({ $0.isWhitespace }) { return false }
        if gap.utf16.count > 20 || badGapRE.test(gap) { return false }
        for tok in gap.split(whereSeparator: { $0 == " " || $0.isWhitespace }) {
            let w = trimEdges(String(tok))
            if w.isEmpty { continue }
            if particles.contains(w.lowercased()) || w.count == 1 || isUpperLike(w.first!) { continue }
            return false
        }
        return true
    }

    static func bridgeNameGaps(_ t: UTF16Text, _ spans: [Span]) -> [Span] {
        if !casingIsInformative(t.string) { return spans }
        let ordered = spans.sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        var out: [Span] = []
        for s in ordered {
            if let p = out.last, nameFamilies.contains(p.label), nameFamilies.contains(s.label),
               s.start >= p.end, gapIsNameLike(t.slice(p.end, s.start)) {
                out[out.count - 1].end = max(p.end, s.end)
            } else {
                out.append(s)
            }
        }
        return out
    }

    static func extendParticleNames(_ t: UTF16Text, _ spans: [Span]) -> [Span] {
        if !casingIsInformative(t.string) { return spans }
        let ordered = spans.sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        var out: [Span] = []
        for var sp in ordered {
            if nameFamilies.contains(sp.label) {
                let trailing = t.slice(sp.start, sp.end).split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
                var consumed = allParticles.contains(trimEdges(trailing).lowercased())
                var pos = sp.end
                while true {
                    let rest = t.slice(pos, t.length)
                    guard let m = nextTokenRE.first(rest) else { break }
                    let tok = m.group(2)!
                    let whole = m.end - m.start
                    let low = trimEdges(tok).lowercased()
                    if allParticles.contains(low) { pos += whole; consumed = true; continue }
                    if consumed, let f = tok.first, isUpperLike(f), String(f) != String(f).lowercased() { pos += whole }
                    break
                }
                if pos > sp.end { sp = Span(sp.start, pos, sp.label, sp.score) }
            }
            out.append(sp)
        }
        return mergeSameLabel(out)
    }

    // MARK: address recognizers
    static func attachBuildingNumbers(_ t: UTF16Text, _ spans: [Span]) -> [Span] {
        var out = spans
        var occ = spans.map { ($0.start, $0.end) }
        func free(_ a: Int, _ b: Int) -> Bool { !occ.contains { $0.0 < b && a < $0.1 } }
        for s in spans where s.label == "STREET_NAME" {
            let after = t.slice(s.end, t.length)
            if let m = bnumAfterRE.first(after), let g = m.range(at: 1) {
                let a = s.end + g.start, b = s.end + g.end
                if free(a, b) { out.append(Span(a, b, "BUILDING_NUMBER")); occ.append((a, b)) }
            }
            let base = max(0, s.start - 8)
            let before = t.slice(base, s.start)
            if let m = bnumBeforeRE.first(before), let g = m.range(at: 1) {
                let a = base + g.start, b = base + g.end
                if free(a, b) { out.append(Span(a, b, "BUILDING_NUMBER")); occ.append((a, b)) }
            }
        }
        return mergeSameLabel(out).sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
    }

    static func redactUsStreet(_ t: UTF16Text, _ spans: [Span]) -> [Span] {
        var out = spans
        for m in usStreetRE.allMatches(t.string) {
            guard let bn = m.range(at: 1), let st0 = m.range(at: 2) else { continue }
            out.removeAll { ($0.label == "STREET_NAME" || $0.label == "BUILDING_NUMBER") && max($0.start, bn.start) < min($0.end, st0.end) }
            out.append(Span(bn.start, bn.end, "BUILDING_NUMBER"))
            out.append(Span(st0.start, st0.end, "STREET_NAME"))
        }
        return mergeSameLabel(out).sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
    }

    static func attachStateCodes(_ t: UTF16Text, _ spans: [Span]) -> [Span] {
        var out = spans
        var occ = spans.map { ($0.start, $0.end) }
        func add(_ a: Int, _ b: Int, _ label: String) {
            if !occ.contains(where: { $0.0 < b && a < $0.1 }) { out.append(Span(a, b, label)); occ.append((a, b)) }
        }
        for m in stateZipRE.allMatches(t.string) {
            guard let sr = m.range(at: 1), let zr = m.range(at: 2) else { continue }
            if usStates.contains(m.group(1)!) {
                add(sr.start, sr.end, "STATE")
                add(zr.start, zr.end, "ZIP_CODE")
            }
        }
        return mergeSameLabel(out).sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
    }

    static func redactSecondaryAddress(_ t: UTF16Text, _ spans: [Span]) -> [Span] {
        var out = spans
        for m in secAddrRE.allMatches(t.string) {
            let s = m.start, e = m.end
            out.removeAll { ($0.label == "SECONDARY_ADDRESS" || $0.label == "BUILDING_NUMBER") && max($0.start, s) < min($0.end, e) }
            out.append(Span(s, e, "SECONDARY_ADDRESS"))
        }
        return mergeSameLabel(out).sorted { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
    }

    // MARK: final label / text tidy (mirrors pipeline.py relabel_by_context + clean_spans)
    private static let trimTrail = Set(" \t\n\r.,;:!?)]}\"\u{00bb}\u{2019}\u{201d}'")
    private static let trimLead = Set(" \t\n\r([{\"\u{00ab}\u{2018}\u{201c}")
    private static let acctLeft = rx(#"(?:\ba/?c\b|acct|account|konto|compte|cuenta|rekening|conta|\biban\b)\W{0,4}#?\s*$"#, ci: true)
    private static let stripTitles: Set<String> = ["mr", "mrs", "ms", "miss", "mx", "master", "mstr", "dr", "prof", "professor", "doctor", "dear", "sir", "madam", "madame", "monsieur", "mme", "mlle", "herr", "frau", "fraulein", "frl", "mevrouw", "dhr", "signor", "signora"]
    private static let titleRE = rx(#"^(\S+)\s+"#)
    private static let titleTrim: Set<Character> = [".", "'", "\u{2019}"]
    private static let coreTrim: Set<Character> = [".", "'", "\u{2019}", " "]

    static func relabelByContext(_ text: String, _ spans: [Span]) -> [Span] {
        let t = UTF16Text(text)
        return spans.map { s in
            var lab = s.label
            let left = t.slice(max(0, s.start - 28), s.start).lowercased()
            if lab == "PHONE", acctLeft.test(left) {
                lab = "BANK_ACCOUNT"
            } else if lab == "GOVERNMENT_ID", (left.contains("driv") && left.contains("licen"))
                || left.contains("f\u{00fc}hrerschein") || left.contains("fuhrerschein")
                || left.contains("rijbewijs") || (left.contains("permis") && left.contains("conduire")) {
                lab = "DRIVERS_LICENSE"
            }
            return Span(s.start, s.end, lab, s.score)
        }
    }

    static func cleanSpans(_ text: String, _ spans: [Span]) -> [Span] {
        let t = UTF16Text(text)
        var out: [Span] = []
        for s in spans {
            var st = s.start, en = s.end
            while en > st, let c = t.scalar(at: en - 1), trimTrail.contains(Character(c)) { en -= 1 }
            while st < en, let c = t.scalar(at: st), trimLead.contains(Character(c)) { st += 1 }
            if nameFamilies.contains(s.label) {
                while st < en {
                    let seg = t.slice(st, en)
                    guard let m = titleRE.first(seg) else { break }
                    let g1 = m.group(1)!
                    if !stripTitles.contains(trim(g1, titleTrim).lowercased()) { break }
                    st += m.end - m.start
                }
                let core = trim(t.slice(st, en), coreTrim)
                if core.isEmpty || stripTitles.contains(core.lowercased()) { continue }
            }
            if en > st { out.append(Span(st, en, s.label, s.score)) }
        }
        return out
    }

    // MARK: hysteresis
    private static func adjacentName(_ t: UTF16Text, _ a: Span, _ b: Span) -> Bool {
        let (lo, hi) = a.start <= b.start ? (a, b) : (b, a)
        if hi.start < lo.end { return true }
        let gap = t.slice(lo.end, hi.start)
        return (gap.allSatisfy({ $0.isWhitespace }) && gap.utf16.count <= 3) || gapIsNameLike(gap)
    }

    static func hysteresis(_ t: UTF16Text, _ scored: [(Span, Double)], _ high: Double) -> [Span] {
        var kept = scored.filter { $0.1 >= high }.map { $0.0 }
        var weak = scored.filter { $0.1 < high && nameFamilies.contains($0.0.label) }.map { $0.0 }
        var changed = true
        while changed && !weak.isEmpty {
            changed = false
            for sp in weak {
                if kept.contains(where: { nameFamilies.contains($0.label) && adjacentName(t, sp, $0) }) {
                    kept.append(sp)
                    weak.removeAll { $0.start == sp.start && $0.end == sp.end && $0.label == sp.label }
                    changed = true
                    break
                }
            }
        }
        return kept
    }

    // MARK: hybrid resolution
    static func resolve(_ detSpans: [Span], _ mlSpans: [Span]) -> [Span] {
        var suppressed = Set<Int>()
        var keptMl: [Span] = []
        for m in mlSpans {
            var conflict = false
            for (i, d) in detSpans.enumerated() where max(m.start, d.start) < min(m.end, d.end) {
                if m.label == d.label { suppressed.insert(i) } else { conflict = true }
            }
            if !conflict { keptMl.append(m) }
        }
        let keptDet = detSpans.enumerated().filter { !suppressed.contains($0.offset) }.map { $0.element }
        return mergeSameLabel(keptDet + keptMl).sorted {
            $0.start != $1.start ? $0.start < $1.start : $0.end != $1.end ? $0.end < $1.end : $0.label < $1.label
        }
    }

    static func maskText(_ text: String, _ spans: [Span]) -> String {
        if text.isEmpty { return text }
        var units = Array(text.utf16)
        let space = " ".utf16.first!
        let newline = "\n".utf16.first!
        for s in spans {
            for i in max(0, s.start)..<min(units.count, s.end) where units[i] != newline {
                units[i] = space
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}
