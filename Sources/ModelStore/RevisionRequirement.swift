// Which model revision a caller wants: a fixed ref, or a semver range over the
// repo's published tags (SwiftPM-style `from:`, i.e. up to the next major).
// Foundation-free like
// the rest of the module's orchestration.

/// A model revision requirement.
///
/// `exact` is any Hub ref used as-is: a tag, branch, or commit hash. Ranges
/// select among the repo's published `v`-tags at resolve time: `from` (the
/// same meaning as SwiftPM's `from:` - up to the next major) picks the highest
/// tag `>= from` with the same major version (`v0.2.0` -> the newest `v0.x`,
/// never `v1.0.0`), so a deployment tracks compatible model updates without
/// chasing a branch. Resolution asks the Hub for tags; offline
/// it falls back to the newest *downloaded* revision in range, then to `from`.
public enum RevisionRequirement: Sendable, Equatable {
    /// A fixed ref, used verbatim (tag, branch, or commit hash).
    case exact(String)
    /// The highest published tag greater than or equal to this one, sharing
    /// its major version (SwiftPM's `from:` semantics). Must be a
    /// semantic-version tag (`v0.2.0` or `0.2.0`).
    case from(String)

    /// The revision when it needs no resolution (`exact`), else nil.
    public var exactRevision: String? {
        if case .exact(let revision) = self { return revision }
        return nil
    }

    /// The best `candidates` entry satisfying this requirement, or nil.
    /// Non-semver candidates never satisfy a range; `exact` matches only
    /// itself. Used both for Hub tags and for the offline cache fallback.
    public func bestMatch(in candidates: [String]) -> String? {
        switch self {
        case .exact(let revision):
            return candidates.contains(revision) ? revision : nil
        case .from(let from):
            guard let floor = SemanticVersion(tag: from) else { return nil }
            return candidates
                .compactMap { tag in SemanticVersion(tag: tag).map { (tag, $0) } }
                .filter { $0.1 >= floor && $0.1.major == floor.major }
                .max { $0.1 < $1.1 }?.0
        }
    }
}

/// A parsed `v`-tag: `v1.2.3`, `1.2.3`, or a shortened `v1.2`/`v1` (missing
/// components are 0). Anything else - branches, commits, prerelease suffixes -
/// does not parse and so never satisfies a ranged requirement.
struct SemanticVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(tag: String) {
        let body = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = Int(part) else { return nil }
            numbers.append(n)
        }
        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}
