import Regex

// The pinned input normalizer, ported from the Python reference in
// src/tongue_training/normalize.py. That module is a frozen specification, not
// an implementation detail: this file must reproduce its output exactly, or the
// model sees different features here than it was trained on. The contract is
// docs/normalizer.md plus normalize_vectors.json — generated in the reference
// repo's golden/ and copied into each port's test resources — replayed by
// TongueTests — change one and you change all of them, in the same commit.
//
// Regex comes from desert-ant-core, the shared primitive every model SDK uses: on
// Android it routes through the host's java.util.regex, so the pipeline holds no
// platform code. NFC is still local (see NFC.swift) only because core's `nfc` is
// unreleased; that file documents how to delete itself once it ships.
//
// Porting hazards this file is deliberate about:
//
//   NFC, not NFKC.  Canonical composition only. NFKC also folds compatibility
//     characters (U+FB01 -> "fi", U+00BD -> "1/2"), which changes the character
//     sequence and therefore every n-gram derived from it.
//   Scalar truncation.  Python slices by code point, so the 512 cap counts
//     Unicode scalars — not grapheme clusters and not UTF-16 units.
//   Invariant lowercase.  `String.lowercased()` is Unicode-default, never
//     locale-aware: Turkish dotted/dotless I would otherwise diverge by locale.
//   General category.  `Unicode.Scalar.Properties.generalCategory` is stdlib,
//     so the symbol/format filter needs no platform support.
//
// Deliberately NOT done: diacritic stripping (ñ, ø, ő, ț are among the strongest
// language signals there are), stemming, or stopword removal.

public enum Normalizer {
    public static let maxCharacters = 512

    // Order is part of the contract; see `normalize(_:)`.
    //
    // Compiling these once matters: rebuilding five per call would dominate a
    // detection that costs tens of microseconds.
    // Every class is spelled out. `\w`, `\d`, `\s` and `\S` are engine-defined and
    // the three engines behind this spec disagree: ICU's `\w` includes combining
    // marks (so `#नमस्ते` vanished entirely here while surviving elsewhere),
    // java.util.regex's are ASCII-only without UNICODE_CHARACTER_CLASS, and
    // JavaScript's `\s` omits U+0085 but adds U+FEFF. Python's are the spec, so
    // they are written out and the same three strings appear in all three ports.
    //
    //   \w  ->  [\p{L}\p{N}_]   verified equal to Python's `\w` over all 0x110000
    //   \d  ->  \p{Nd}          verified equal to Python's `\d` (650 scalars)
    //   \s  ->  the 29 scalars below, which is exactly Python's `\s`
    static let whitespaceClass =
        "\u{09}-\u{0D}\u{1C}-\u{20}\u{85}\u{A0}\u{1680}\u{2000}-\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}"
    private static let nonWhitespace = "[^\(whitespaceClass)]"

    private static let url = pattern(#"(?:https?://|www\.)"# + nonWhitespace + "+", ignoringCase: true)
    private static let email = pattern(nonWhitespace + "+@" + nonWhitespace + #"+\."# + nonWhitespace + "+")
    private static let mention = pattern(#"[@#][\p{L}\p{N}_]+"#)
    private static let digits = pattern(#"\p{Nd}+"#)
    private static let whitespace = pattern("[\(whitespaceClass)]+")

    // Emoji, symbol modifiers and invisible formatting characters: they carry no
    // language signal but do perturb the n-gram bag.
    //
    // From the generated table rather than `generalCategory`, because that answers
    // from the runtime's Unicode version and the model was trained on 13.0.0 — a
    // newer OS would otherwise keep scalars the training data discarded. See
    // DiscardTable.swift.
    static func isDiscarded(_ scalar: Unicode.Scalar) -> Bool {
        var low = 0
        var high = discardedRanges.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let (start, end) = discardedRanges[mid]
            if scalar.value < start { high = mid - 1 }
            else if scalar.value > end { low = mid + 1 }
            else { return true }
        }
        return false
    }

    private static func pattern(_ source: String, ignoringCase: Bool = false) -> Pattern {
        // Force-try: these are literals in this file, so a bad pattern is a
        // programming error the first test run catches, not a runtime path.
        let compiled = try! Pattern(source)
        return ignoringCase ? compiled.ignoresCase() : compiled
    }

    /// Replace every match with a single space.
    ///
    /// `Regex` reports match ranges rather than offering substitution, so this
    /// walks the matches in reverse and splices — reverse order keeps the earlier
    /// indices valid as the string is mutated.
    private static func replacingMatches(_ pattern: Pattern, in text: String) -> String {
        let matches = pattern.matches(in: text)
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() { result.replaceSubrange(match.range, with: " ") }
        return result
    }

    /// Apply the frozen normalization pipeline.
    ///
    /// 1. Unicode NFC
    /// 2. remove URLs, then emails, then @mentions and #hashtags
    /// 3. remove digit runs
    /// 4. remove symbol and format characters
    /// 5. invariant lowercase
    /// 6. collapse whitespace runs to one space and trim the ends
    /// 7. truncate to `maxCharacters` Unicode scalars
    public static func normalize(_ text: String) -> String {
        var result = text.nfc
        result = replacingMatches(url, in: result)
        result = replacingMatches(email, in: result)
        result = replacingMatches(mention, in: result)
        result = replacingMatches(digits, in: result)
        result = String(String.UnicodeScalarView(
            result.unicodeScalars.filter { !isDiscarded($0) }
        ))
        result = lowercasedMatchingPython(result)
        result = trimmed(replacingMatches(whitespace, in: result))
        guard result.unicodeScalars.count > maxCharacters else { return result }
        return String(String.UnicodeScalarView(result.unicodeScalars.prefix(maxCharacters)))
    }

    /// `lowercased()` with the Final_Sigma rule applied, which Swift's does not do.
    ///
    /// Python, JavaScript and Java all lowercase `ΟΔΟΣ` to `οδος`; Swift alone
    /// gives `οδοσ`. Greek all-caps is ordinary text (headlines, signage), and
    /// `Detection.normalized` is public API, so the odd one out has to be fixed
    /// rather than documented.
    ///
    /// Unicode SpecialCasing: a capital sigma lowercases to final sigma when it is
    /// preceded by a cased letter (ignoring case-ignorable scalars) and not
    /// followed by one. Substituting before `lowercased()` rather than after means
    /// sigmas already lowercase in the input are left exactly as the caller wrote
    /// them, which is also what Python does.
    private static func lowercasedMatchingPython(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains(where: { $0 == "\u{03A3}" }) else { return text.lowercased() }

        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)
        for (index, scalar) in scalars.enumerated() {
            guard scalar == "\u{03A3}" else { out.append(scalar); continue }
            out.append(isFinalSigma(scalars, at: index) ? "\u{03C2}" : "\u{03C3}")
        }
        return String(out).lowercased()
    }

    private static func isFinalSigma(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        var before = index - 1
        while before >= 0, scalars[before].properties.isCaseIgnorable { before -= 1 }
        guard before >= 0, scalars[before].properties.isCased else { return false }

        var after = index + 1
        while after < scalars.count, scalars[after].properties.isCaseIgnorable { after += 1 }
        return after >= scalars.count || !scalars[after].properties.isCased
    }

    /// Hand-rolled so this file needs no Foundation: `Character.isWhitespace` is
    /// stdlib, and the only whitespace left by step 6 is the single spaces it
    /// collapsed to.
    private static func trimmed(_ text: String) -> String {
        var slice = Substring(text)
        while let first = slice.first, first.isWhitespace { slice.removeFirst() }
        while let last = slice.last, last.isWhitespace { slice.removeLast() }
        return String(slice)
    }

    /// Whitespace tokens of already-normalized text.
    public static func tokens(_ text: String) -> [String] {
        // Scalars, not Characters: a space followed by a combining mark is a single
        // grapheme cluster, so `text.split` would not cut there. See Hashing.swift.
        text.isEmpty
            ? []
            : text.unicodeScalars
                .split(separator: " ", omittingEmptySubsequences: false)
                .map { String(String.UnicodeScalarView($0)) }
    }
}
