/// `Pattern`: a regex API shaped like the standard library's `Regex`, backed
/// by each platform's own engine (Foundation on Apple/Linux, `java.util.regex`
/// on Android, the JS engine on wasm). Model-agnostic and reusable.
///
/// The type is `Pattern` (not `Regex`) because a type named `Regex` would clash
/// with the standard library's `Regex` and can't be module-qualified; the
/// module is still `Regex`, so `import Regex` then use `Pattern` / `rx` / `regex`.
///
/// ```swift
/// let re = try regex(#"(\d{4})-(\d{2})"#)     // or try Pattern(...)
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
public struct Pattern {
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
    public func ignoresCase(_ ignore: Bool = true) -> Pattern {
        (try? Pattern(pattern, caseInsensitive: ignore)) ?? self
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
        guard let groups = anchored("^(?:\(pattern))$")?.matches(in: text, firstOnly: true).first else {
            return nil
        }
        let match = Match(text: text, groups: groups)
        return match.range.upperBound == text.endIndex ? match : nil
    }

    /// A match only if the pattern matches a prefix of `text`.
    public func prefixMatch(in text: String) -> Match? {
        anchored("^(?:\(pattern))")?.matches(in: text, firstOnly: true).first
            .map { Match(text: text, groups: $0) }
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

    /// This match represented with UTF-16 offsets. Useful at FFI boundaries and
    /// for pipelines shared with JavaScript, JVM, or Core ML code.
    public func utf16Offsets(in text: String) -> UTF16Match {
        UTF16Match(match: self, text: text)
    }
}

/// A regex match represented in UTF-16 code-unit offsets.
public struct UTF16Match {
    public struct Capture {
        public let range: Range<Int>?
        public let substring: Substring?
    }

    private let captures: [Capture]

    fileprivate init(match: Match, text: String) {
        captures = (0..<match.count).map { index in
            let capture = match[index]
            return Capture(
                range: capture.range.map {
                    $0.lowerBound.utf16Offset(in: text)..<$0.upperBound.utf16Offset(in: text)
                },
                substring: capture.substring
            )
        }
    }

    public var range: Range<Int> { captures[0].range! }
    public var substring: Substring { captures[0].substring! }
    public var count: Int { captures.count }
    public subscript(_ index: Int) -> Capture {
        (index >= 0 && index < captures.count) ? captures[index] : Capture(range: nil, substring: nil)
    }
}

public extension Pattern {
    /// The first match represented with UTF-16 offsets.
    func firstUTF16Match(in text: String) -> UTF16Match? {
        firstMatch(in: text)?.utf16Offsets(in: text)
    }

    /// Every match represented with UTF-16 offsets.
    func utf16Matches(in text: String) -> [UTF16Match] {
        matches(in: text).map { $0.utf16Offsets(in: text) }
    }
}

/// Compile a compile-time-constant pattern, trapping on an invalid literal.
/// Prefer `regex(_:)` (or `try Pattern(_:)`) for user-supplied patterns.
public func rx(_ pattern: String, ci: Bool = false) -> Pattern {
    let compiled = try! Pattern(pattern)
    return ci ? compiled.ignoresCase() : compiled
}

/// Compile a (possibly user-supplied) pattern, throwing on an invalid one.
/// A convenience alongside `Pattern(_:)` for callers who prefer a free function.
public func regex(_ pattern: String, ignoresCase: Bool = false) throws -> Pattern {
    let compiled = try Pattern(pattern)
    return ignoresCase ? compiled.ignoresCase() : compiled
}
