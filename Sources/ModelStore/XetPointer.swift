// What the Hub tells us about a file's Xet storage, and nothing about how it is
// fetched: this file is Foundation-free and compiles on every platform so the
// parsing is testable without the `Xet` trait (the transport that uses it is
// Apple-only, see XetTransport.swift).

/// A file's coordinates in Hugging Face's content-addressable storage.
///
/// Hub files are served twice over: an ordinary LFS redirect, and - for repos
/// migrated to Xet, which ours are - a content-defined chunk stream that
/// deduplicates against chunks already on disk and downloads the rest in
/// parallel. A `HEAD` on the usual `resolve` URL carries both: `X-Xet-Hash` is
/// the Merkle hash the CAS reconstructs the file from, and the `Link` header's
/// `xet-auth` relation is where a read token for it comes from.
public struct XetPointer: Sendable, Equatable {
    /// 64-char hex Merkle hash of the file's contents (`X-Xet-Hash`).
    public let fileID: String
    /// Hub endpoint that mints a short-lived CAS read token.
    public let refreshURL: String

    public init(fileID: String, refreshURL: String) {
        self.fileID = fileID
        self.refreshURL = refreshURL
    }

    /// Build a pointer from the two response headers, or `nil` when the file is
    /// not Xet-backed (small git-tracked files never are) or the headers are not
    /// what we expect. `nil` is not an error: it means "download this the plain
    /// way".
    ///
    /// - Parameter resolveURL: the `resolve` URL the headers came from, used for
    ///   the refresh endpoint when the `Link` header is absent. The Hub has
    ///   served that header since Xet shipped, but a proxy or a mirror endpoint
    ///   may drop it, and the endpoint is derivable.
    public static func from(xetHash: String?, link: String?, resolveURL: String) -> XetPointer? {
        guard let xetHash, isFileID(xetHash) else { return nil }
        guard let refresh = link.flatMap(authURL(inLink:)) ?? readTokenURL(forResolveURL: resolveURL)
        else { return nil }
        return XetPointer(fileID: xetHash, refreshURL: refresh)
    }

    /// A CAS file id is a 64-char lowercase-or-upper hex hash. Rejecting
    /// anything else here keeps a surprising header out of a URL path.
    static func isFileID(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    /// The `xet-auth` target from an RFC 8288 `Link` header:
    /// `<url>; rel="xet-auth", <url>; rel="xet-reconstruction-info"`.
    static func authURL(inLink link: String) -> String? {
        for section in sections(of: link) {
            guard let open = section.firstIndex(of: "<"),
                  let close = section[open...].firstIndex(of: ">") else { continue }
            let target = String(section[section.index(after: open)..<close])
            let params = section[section.index(after: close)...].lowercased()
                .filter { $0 != " " && $0 != "\"" }
            guard params.contains("rel=xet-auth"), target.hasPrefix("https://") else { continue }
            return target
        }
        return nil
    }

    /// Split a `Link` header on the commas that separate its entries, ignoring
    /// commas inside `<...>` - the signed CDN URLs the Hub returns are full of
    /// them.
    private static func sections(of link: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inAngle = false
        for ch in link {
            switch ch {
            case "<": inAngle = true; current.append(ch)
            case ">": inAngle = false; current.append(ch)
            case "," where !inAngle: out.append(current); current = ""
            default: current.append(ch)
            }
        }
        out.append(current)
        return out
    }

    /// `<endpoint>/<repo>/resolve/<rev>/<file>` ->
    /// `<endpoint>/api/models/<repo>/xet-read-token/<rev>`.
    static func readTokenURL(forResolveURL url: String) -> String? {
        // Split rather than search for "/resolve/": String.range(of:) is
        // Foundation, which this module keeps out of every file but one.
        // "https://host/owner/repo/resolve/<rev>/<file>" is
        // ["https:", "", "host", "owner", "repo", "resolve", rev, ...], so the
        // marker is never before index 5 and a repo literally named "resolve"
        // cannot be mistaken for it.
        let parts = url.split(separator: "/", omittingEmptySubsequences: false)
        guard let marker = parts.dropFirst(5).firstIndex(of: "resolve"),
              marker + 1 < parts.count else { return nil }
        let endpoint = parts[..<(marker - 2)].joined(separator: "/")
        let repo = parts[(marker - 2)..<marker].joined(separator: "/")
        let revision = parts[marker + 1]
        guard !endpoint.isEmpty, !repo.isEmpty, !revision.isEmpty else { return nil }
        return "\(endpoint)/api/models/\(repo)/xet-read-token/\(revision)"
    }
}
