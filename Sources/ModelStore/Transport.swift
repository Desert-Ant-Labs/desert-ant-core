// The two per-platform seams (Foundation-free protocols): HTTP transport and
// filesystem. Apple/Linux back them with URLSession/FileManager
// (FoundationBackend.swift); Android and wasm back them with the host
// (java.net / JS fetch, POSIX / node fs). URLs and paths are plain strings so
// nothing Foundation crosses the seam.

/// One file in a repo, from the Hub tree listing.
public struct RemoteEntry: Sendable, Equatable {
    /// Repo-relative path.
    public let path: String
    /// Size in bytes.
    public let size: Int64
    /// Content SHA-256 for LFS files (the large weights); `nil` for small
    /// git-tracked files, whose hash is computed on download instead.
    public let sha256: String?

    public init(path: String, size: Int64, sha256: String?) {
        self.path = path; self.size = size; self.sha256 = sha256
    }
}

/// HTTP seam. `tree` lists a repo's files (Hub tree API: path + size + LFS
/// sha256, folders included) so one call resolves folders and supplies
/// verification hashes; `download` streams a file, reporting cumulative bytes.
public protocol ModelTransport: Sendable {
    func tree(_ url: String) async throws -> [RemoteEntry]
    func download(_ url: String, to destinationPath: String, onBytes: @escaping @Sendable (Int64) -> Void) async throws
}

/// Filesystem seam: the small set of operations the store needs. `move` must be
/// atomic on the same volume (rename), so a crash never leaves a half file at a
/// final path.
public protocol FileSystem: Sendable {
    func exists(_ path: String) -> Bool
    func size(_ path: String) -> Int64?
    func read(_ path: String) throws -> [UInt8]
    func write(_ path: String, _ bytes: [UInt8]) throws
    func makeDirectory(_ path: String) throws           // mkdir -p
    func move(_ from: String, to: String) throws        // atomic rename
    func remove(_ path: String)                         // best-effort
    /// Default cache root when a model gives no `cacheDirectory`.
    func defaultCacheRoot() -> String
}

public enum ModelStoreError: Error, CustomStringConvertible {
    /// A requested file or folder is not in the repo at that revision.
    case notInRepo(String)
    /// A download completed but failed its size/hash integrity check.
    case integrityCheckFailed(String)
    /// A transport/HTTP or filesystem failure.
    case io(String)

    public var description: String {
        switch self {
        case let .notInRepo(f): "\(f) is not in the repo at that revision"
        case let .integrityCheckFailed(f): "integrity check failed for \(f)"
        case let .io(m): m
        }
    }
}
