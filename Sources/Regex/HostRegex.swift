#if os(Android)
import CHostBridge

/// Regex engine for Android: the host's `java.util.regex` via CHostBridge. The
/// host returns newline-separated matches, each `"g0s,g0e;g1s,g1e;..."` of
/// UTF-16 group offsets (`-1,-1` for an unmatched group).
struct RegexEngine {
    private let pattern: String
    private let caseInsensitive: Bool

    // The host compiles lazily; a bad pattern yields no matches rather than
    // throwing (patterns here are compile-time constants).
    init(_ pattern: String, caseInsensitive: Bool) throws {
        self.pattern = pattern
        self.caseInsensitive = caseInsensitive
    }

    func matches(in text: String, firstOnly: Bool) -> [[(start: Int, end: Int)?]] {
        guard let ptr = pattern.withCString({ p in
            text.withCString { t in host_regex_matches(p, caseInsensitive ? 1 : 0, t, firstOnly ? 1 : 0) }
        }) else { return [] }
        defer { host_free(ptr) }
        let encoded = String(cString: ptr)
        if encoded.isEmpty { return [] }
        return encoded.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            line.split(separator: ";", omittingEmptySubsequences: false).map { field -> (start: Int, end: Int)? in
                let parts = field.split(separator: ",", omittingEmptySubsequences: false)
                guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]),
                      start >= 0, end >= start else { return nil }
                return (start, end)
            }
        }
    }
}
#endif
