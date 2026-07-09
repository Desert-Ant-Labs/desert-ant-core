/// `String` matching that reads exactly like the standard library, e.g.
/// `text.firstMatch(of: re)` / `text.matches(of: re)`.
///
/// These are plain overloads taking our concrete `Pattern`. The stdlib versions
/// are generic over `RegexComponent`, which our `Pattern` deliberately does not
/// conform to (that would force the stdlib engine), so there is no ambiguity:
/// a `Pattern` argument selects these; a stdlib regex selects the stdlib ones.
public extension String {
    /// The first match of `regex` anywhere in `self`, or `nil`.
    func firstMatch(of regex: Pattern) -> Match? { regex.firstMatch(in: self) }
    /// Every non-overlapping match of `regex` in `self`, left to right.
    func matches(of regex: Pattern) -> [Match] { regex.matches(in: self) }
    /// A match only if `regex` matches the whole of `self`.
    func wholeMatch(of regex: Pattern) -> Match? { regex.wholeMatch(in: self) }
    /// A match only if `regex` matches a prefix of `self`.
    func prefixMatch(of regex: Pattern) -> Match? { regex.prefixMatch(in: self) }
    /// Whether `self` contains a match of `regex`.
    func contains(_ regex: Pattern) -> Bool { regex.contains(in: self) }
}
