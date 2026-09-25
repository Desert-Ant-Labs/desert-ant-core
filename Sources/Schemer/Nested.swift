// Arrays of objects, by segment and recurse.
//
// A port of the reference harness (schemer-training training/v60/
// nested_infer.py), rule for rule, because that is what the nested numbers
// were measured with. There is no nested head in the model: the text is split
// into candidate item spans, the flat pipeline runs on each with the item's
// properties as its schema, and the answers are assembled. So it works where
// each item has its own clause or list entry ("Lisbon for 3 nights at X, then
// Porto for 2 nights at Y"), and fields bleed between items that share one.
//
// Lengths and trims are in Unicode scalars, as Python's `str` counts them.

import Foundation

enum Nested {
    static let maxItems = 16
    static let minSegmentScalars = 6

    /// Sentence-ish boundaries, CJK included; the delimiters are dropped. A
    /// "." between two digits is a decimal point, not a boundary: splitting
    /// there read "at 35.50" as "at 35" and a "50 each, ..." segment.
    private static let sentences = rx(#"(?:(?<!\d)\.|\.(?!\d)|[;\n。；！？!?])+"#)
    /// Intra-sentence list glue across the supported languages.
    private static let glue = rx(
        #",\s*(?:then|danach|puis|luego|daarna|depois|poi|sedan|deretter|potem)\s+"#
        + #"|;\s+|\s+\d+[).]\s+|、|，"#, .caseInsensitive)
    /// "Trip plan: ", and "Gym log — ".
    private static let lead = rx(#"^[^:：]{0,40}[:：]\s*"#)
    private static let dashLead = rx(#"^[^—–-]{0,40}[—–]\s*"#)

    private static func rx(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: p, options: o)
    }

    /// Candidate item spans: sentences, then glue-split inside them.
    ///
    /// Stripping a lead ("Trip plan: X") is ambiguous with a key-value item
    /// ("incline rows: 3 sets of 15"): stripping it alone once returned empty
    /// arrays for every workout. So both variants are candidates, and
    /// assembly drops the extras.
    static func segment(_ text: String) -> [String] { segmentReportingCap(text).segments }

    /// `segment`, and whether candidates past the cap were dropped, so part
    /// of the text was never read.
    static func segmentReportingCap(_ text: String) -> (segments: [String], capped: Bool) {
        var segs: [String] = []

        func addParts(_ s: String) {
            let parts = split(s, glue).map(strip)
            for p in parts {
                if count(p) >= minSegmentScalars { segs.append(p) }
                // Plain-comma items ("19x docking stations, 10x keyboard
                // trays") never hit the glue; emit comma-split candidates too.
                for q in p.components(separatedBy: ", ") {
                    let q = strip(q)
                    if count(q) >= minSegmentScalars, q != p { segs.append(q) }
                }
            }
            if parts.count > 1, count(s) >= minSegmentScalars { segs.append(strip(s)) }
        }

        for raw in split(text, sentences) {
            let sent = raw.trimmingCharacters(in: pythonWhitespace)
            if sent.isEmpty { continue }
            addParts(sent)
            let stripped = replaceFirst(replaceFirst(sent, lead), dashLead)
            if stripped != sent, count(stripped) >= minSegmentScalars { addParts(stripped) }
        }
        var seen = Set<String>(), unique: [String] = []
        for s in segs where seen.insert(s).inserted { unique.append(s) }
        return (Array(unique.prefix(maxItems * 4)), unique.count > maxItems * 4)
    }

    /// The property whose presence decides that a segment holds an item: the
    /// first string property, else the first.
    static func anchor(_ properties: [Field]) -> Field {
        properties.first { if case .string = $0.kind { return true } else { return false } }
            ?? properties[0]
    }

    /// What the reference treats as not stated: None, "" and [].
    static func isEmpty(_ v: Value) -> Bool {
        switch v {
        case .null: return true
        case .string(let s), .label(let s), .datetime(let s): return s.isEmpty
        case .array(let xs): return xs.isEmpty
        case .objects(let xs): return xs.isEmpty
        case .number, .boolean: return false
        }
    }

    /// Drop exact duplicates, objects that are a subset of another (the
    /// overlapping candidates produce partial copies of one item), and
    /// chimeras: an object whose items are jointly covered by two others
    /// while being a subset of neither, which the whole-sentence candidate
    /// makes by fusing two real items ({Lisbon, 3, Hotel Miradouro} from a
    /// Lisbon-and-Porto sentence).
    static func dedupe(_ objs: [Record]) -> [Record] {
        var out: [Record] = []
        for o in objs {
            let oi = items(o)
            var dominated = false
            for i in out.indices {
                let ki = items(out[i])
                if oi.isSubset(of: ki) { dominated = true; break }
                if ki.isStrictSubset(of: oi) { out[i] = o; dominated = true; break }
            }
            if !dominated { out.append(o) }
        }
        let all = out.map(items)
        var keep: [Record] = []
        for (i, o) in out.enumerated() {
            let oi = all[i]
            let others = all.indices.filter { $0 != i }.map { all[$0] }
            if others.contains(where: { oi.isSubset(of: $0) }) { continue }
            var chimera = false
            outer: for a in others.indices {
                for b in (a + 1)..<others.count {
                    let x = others[a], y = others[b]
                    if oi.isSubset(of: x.union(y)), !oi.isSubset(of: x), !oi.isSubset(of: y) {
                        chimera = true
                        break outer
                    }
                }
            }
            if !chimera { keep.append(o) }
        }
        return Array(keep.prefix(maxItems))
    }

    /// `_drop_spanning`: drop the object a candidate read when the candidates
    /// inside its span read better ones. Spanning two that found different
    /// items, it read one object out of several, and fuses them ({chairs, 36,
    /// 189} out of "2 chairs at 189 each, 4 arms at 36 each"). Spanning one
    /// that read the same item differently, the inner one is the tighter
    /// reading ("Order from X: 2 chairs at 189" read quantity 189 beside "2
    /// chairs at 189"); an inner reading that is only a part of the outer one
    /// is left to `dedupe`, which keeps the fuller ("UA 523" beside the
    /// sentence that also names the cities).
    ///
    /// Then the survivors in the order the text states them: candidates come
    /// out whole-sentence first and lead-stripped variants after. `find` is
    /// Python's `str.find`, the first occurrence, so ties keep their order.
    static func dropSpanning(_ found: [(segment: String, anchor: Value, record: Record)],
                             in text: String) -> [Record] {
        var keep: [(Int, Int, Record)] = []
        for (i, f) in found.enumerated() {
            let inner = found.filter {
                $0.segment != f.segment && position(of: $0.segment, in: f.segment) >= 0
            }
            if Set(inner.map(\.anchor)).count >= 2 { continue }
            let mine = items(f.record)
            if inner.contains(where: { $0.anchor == f.anchor && !items($0.record).isSubset(of: mine) }) {
                continue
            }
            keep.append((position(of: f.segment, in: text), i, f.record))
        }
        return keep.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.map(\.2)
    }

    /// `str.find` in scalars, -1 when absent. A literal search compares code
    /// units, as Python compares code points; `String.contains` would compare
    /// graphemes, and miss a match that splits a combining sequence.
    private static func position(of needle: String, in haystack: String) -> Int {
        guard let r = haystack.range(of: needle, options: .literal) else { return -1 }
        return haystack.unicodeScalars.distance(from: haystack.unicodeScalars.startIndex, to: r.lowerBound)
    }

    /// An object's non-null entries, as comparable items.
    private static func items(_ r: Record) -> Set<Item> {
        Set(zip(r.names, r.values).compactMap { $1 == .null ? nil : Item(name: $0, value: $1) })
    }

    private struct Item: Hashable {
        let name: String
        let value: Value
    }

    // MARK: - Python string semantics

    /// `re.split`: the pieces between matches, empty ones included.
    private static func split(_ s: String, _ re: NSRegularExpression) -> [String] {
        let ns = s as NSString
        var out: [String] = [], last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        out.append(ns.substring(from: last))
        return out
    }

    private static func replaceFirst(_ s: String, _ re: NSRegularExpression) -> String {
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
        else { return s }
        return (s as NSString).replacingCharacters(in: m.range, with: "")
    }

    /// `str.strip(" ,;-—–")`.
    private static let stripSet = CharacterSet(charactersIn: " ,;-\u{2014}\u{2013}")
    private static func strip(_ s: String) -> String { trim(s, stripSet) }

    /// `str.strip()` with no argument: Unicode whitespace.
    private static let pythonWhitespace = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{1C}\u{1D}\u{1E}\u{1F}"))

    /// Trims by Unicode scalar, as Python does, not by grapheme: a trailing
    /// combining mark after a stripped character must not keep it alive.
    private static func trim(_ s: String, _ set: CharacterSet) -> String {
        let scalars = Array(s.unicodeScalars)
        var a = 0, b = scalars.count
        while a < b, set.contains(scalars[a]) { a += 1 }
        while b > a, set.contains(scalars[b - 1]) { b -= 1 }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars[a..<b])
        return String(out)
    }

    private static func count(_ s: String) -> Int { s.unicodeScalars.count }
}

extension Value: Hashable {
    public func hash(into h: inout Hasher) {
        switch self {
        case .null: h.combine(0)
        case .string(let s): h.combine(1); h.combine(s)
        case .number(let d): h.combine(2); h.combine(d)
        case .boolean(let b): h.combine(3); h.combine(b)
        case .datetime(let s): h.combine(4); h.combine(s)
        case .label(let s): h.combine(5); h.combine(s)
        case .array(let xs): h.combine(6); h.combine(xs)
        case .objects(let xs): h.combine(7); h.combine(xs.count)
        }
    }
}

extension Model {
    /// Extract an `objects` field: every segment's item, assembled.
    ///
    /// - Parameters:
    ///   - anchor: the `today=` string each segment is encoded with, and
    ///     `trustedAnchor` whether it is a real date. The public path passes
    ///     the caller's `now` for both, as it does for flat fields. The
    ///     reference shows a segment its default anchor (a segment's text is
    ///     never in its anchor map), which is what the eval conformance test
    ///     passes to compare against it.
    func objects(text: String, properties: [Field], anchor: String,
                 trustedAnchor: Bool = true) async throws -> Value {
        var truncated = false
        return try await objects(text: text, properties: properties, anchor: anchor,
                                 trustedAnchor: trustedAnchor, truncated: &truncated)
    }

    func objects(text: String, properties: [Field], anchor: String,
                 trustedAnchor: Bool = true, truncated: inout Bool) async throws -> Value {
        guard !properties.isEmpty else { return .objects([]) }
        let key = Nested.anchor(properties)
        let hasDT = properties.contains(where: \.isDatetime)
        var found: [(segment: String, anchor: Value, record: Record)] = []
        let (segments, capped) = Nested.segmentReportingCap(text)
        if capped { truncated = true }
        for seg in segments {
            // The anchor first, and the rest only when it is there: every
            // field is decided independently, so this is the reference's
            // answer at a fraction of its cost on segments that hold nothing.
            let head = try await one(seg, key, anchor, trustedAnchor, hasDT, &truncated)
            if Nested.isEmpty(head) { continue }
            var entries: [(String, Value)] = []
            for p in properties {
                let v = p.name == key.name
                    ? head : try await one(seg, p, anchor, trustedAnchor, hasDT, &truncated)
                if !Nested.isEmpty(v) { entries.append((p.name, v)) }
            }
            found.append((seg, head, Record(entries)))
        }
        return .objects(Nested.dedupe(Nested.dropSpanning(found, in: text)))
    }

    private func one(_ text: String, _ field: Field, _ anchor: String, _ trusted: Bool,
                     _ hasDT: Bool, _ truncated: inout Bool) async throws -> Value {
        let s = try await stage(text: text, field: field, anchor: anchor)
        if s.truncated { truncated = true }
        return try await decodeValue(s, text: text, field: field, modelAnchor: anchor,
                                     trustedAnchor: trusted, hasDatetimeSibling: hasDT)
    }
}
