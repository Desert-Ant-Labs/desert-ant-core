#if canImport(Foundation) && !os(Android) && !os(WASI)
import Foundation

/// Regex engine for Foundation platforms (Apple/Linux): `NSRegularExpression`.
/// Produces per-match UTF-16 group ranges; `Regex`/`Match` turn them into
/// `Range<String.Index>`.
struct RegexEngine {
    private let regex: NSRegularExpression

    init(_ pattern: String, caseInsensitive: Bool) throws {
        regex = try NSRegularExpression(
            pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    func matches(in text: String, firstOnly: Bool) -> [[(start: Int, end: Int)?]] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var out: [[(start: Int, end: Int)?]] = []
        if firstOnly {
            if let m = regex.firstMatch(in: text, range: full) { out.append(groups(m)) }
        } else {
            regex.enumerateMatches(in: text, range: full) { m, _, _ in
                if let m { out.append(groups(m)) }
            }
        }
        return out
    }

    private func groups(_ m: NSTextCheckingResult) -> [(start: Int, end: Int)?] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : (r.location, r.location + r.length)
        }
    }
}
#endif
