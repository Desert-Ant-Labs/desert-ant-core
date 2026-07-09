/// Regex: a regex API shaped like the standard library's `Regex`, backed
/// by each platform's own engine (Foundation on Apple/Linux, `java.util.regex`
/// on Android, the JS engine on wasm). Model-agnostic and reusable.
///
/// ```swift
/// let re = try Regex(#"(\d{4})-(\d{2})"#)
/// if let m = text.firstMatch(of: re) {     // stdlib-shaped (see StringMatching)
///     m.range          // Range<String.Index>  (whole match)
///     m[1].substring   // Substring?           (capture 1)
/// }
/// for m in text.matches(of: re) { ... }
/// ```
///
/// `String` overloads (`text.firstMatch(of:)`, `text.matches(of:)`, ...) make
/// the call sites identical to the standard library; the equivalent methods on
/// the regex itself (`re.firstMatch(in:)`, ...) are also available. This does
/// not conform to `RegexComponent` (that would force the stdlib engine), so
/// regex literals and generic `RegexComponent` contexts still won't accept it.
/// Patterns are the common ICU/JS/Java subset (no inline `(?i)` flags or
/// possessive quantifiers; `\p{...}` is fine).
public struct Regex {
    private let pattern: String
    private let caseInsensitive: Bool
    private let engine: RegexEngine

    /// Compile `pattern`. Throws on an invalid pattern.
    public init(_ pattern: String) throws {
        try self.init(pattern, caseInsensitive: false)
    }

    private init(_ pattern: String, caseInsensitive: Bool) throws {
        self.pattern = pattern
        self.caseInsensitive = caseInsensitive
        self.engine = try RegexEngine(pattern, caseInsensitive: caseInsensitive)
    }

    /// A copy that matches case-insensitively (mirrors `Regex.ignoresCase()`).
    public func ignoresCase(_ ignore: Bool = true) -> Regex {
        (try? Regex(pattern, caseInsensitive: ignore)) ?? self
    }

    /// The first match anywhere in `text`, or `nil`.
    public func firstMatch(in text: String) -> Match? {
        engine.matches(in: text, firstOnly: true).first.map { Match(text: text, groups: $0) }
    }

    /// Every non-overlapping match in `text`, left to right.
    public func matches(in text: String) -> [Match] {
        engine.matches(in: text, firstOnly: false).map { Match(text: text, groups: $0) }
    }

    /// A match only if the pattern matches the whole of `text`.
    public func wholeMatch(in text: String) -> Match? {
        anchored("^(?:\(pattern))$")?.matches(in: text, firstOnly: true).first.map { Match(text: text, groups: $0) }
    }

    /// A match only if the pattern matches a prefix of `text`.
    public func prefixMatch(in text: String) -> Match? {
        anchored("^(?:\(pattern))")?.matches(in: text, firstOnly: true).first.map { Match(text: text, groups: $0) }
    }

    /// Whether `text` contains a match (mirrors `text.contains(regex)`).
    public func contains(in text: String) -> Bool { firstMatch(in: text) != nil }

    private func anchored(_ pattern: String) -> RegexEngine? {
        try? RegexEngine(pattern, caseInsensitive: caseInsensitive)
    }
}

/// A regex match: capture groups as `Range<String.Index>` + `Substring`
/// (index 0 is the whole match), mirroring the standard library.
public struct Match {
    /// One capture group. `range`/`substring` are `nil` for an unmatched
    /// optional group.
    public struct Capture {
        public let range: Range<String.Index>?
        public let substring: Substring?
    }

    private let captures: [Capture]

    init(text: String, groups: [(start: Int, end: Int)?]) {
        captures = groups.map { group in
            guard let group else { return Capture(range: nil, substring: nil) }
            let lo = String.Index(utf16Offset: group.start, in: text)
            let hi = String.Index(utf16Offset: group.end, in: text)
            return Capture(range: lo..<hi, substring: text[lo..<hi])
        }
    }

    /// The whole match's range.
    public var range: Range<String.Index> { captures[0].range! }
    /// The whole matched substring.
    public var substring: Substring { captures[0].substring! }
    /// Number of capture groups, including group 0 (the whole match).
    public var count: Int { captures.count }
    /// Capture group `index` (0 = whole match); out of range yields an empty
    /// capture.
    public subscript(_ index: Int) -> Capture {
        (index >= 0 && index < captures.count) ? captures[index] : Capture(range: nil, substring: nil)
    }
}

/// Compile a compile-time-constant pattern, trapping on an invalid literal.
/// Prefer `regex(_:)` (or `try Regex(_:)`) for user-supplied patterns.
public func rx(_ pattern: String, ci: Bool = false) -> Regex {
    let regex = try! Regex(pattern)
    return ci ? regex.ignoresCase() : regex
}

/// Compile a (possibly user-supplied) pattern, throwing on an invalid one.
///
/// A free function because the type is named `Regex`, which collides with the
/// standard library's `Regex` at a call site that does `import Regex`; `regex(_:)`,
/// `rx(_:)`, and the `String` matching methods let callers avoid naming the type
/// (or qualify it as `Regex.Regex`).
public func regex(_ pattern: String, ignoresCase: Bool = false) throws -> Regex {
    let compiled = try Regex(pattern)
    return ignoresCase ? compiled.ignoresCase() : compiled
}
