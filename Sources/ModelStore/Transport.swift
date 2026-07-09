// The two per-platform seams (Foundation-free protocols): HTTP transport and
// filesystem. Apple/Linux back them with URLSession/FileManager
// (FoundationBackend.swift); Android and wasm will back them with the host
// (java.net / JS fetch, POSIX / host storage). URLs and paths are plain
// strings so nothing Foundation crosses the seam.

/// What a `HEAD` on a Hub `resolve` URL tells us about a file.
public struct RemoteFileInfo: Sendable {
    /// The server's content hash, if any. For Hugging Face LFS files (the large
    /// weights) this is the lowercase SHA-256; for small non-LFS files it's the
    /// git blob hash (not a content hash).
    public let etag: String?
    /// The commit the revision resolved to (`X-Repo-Commit`).
    public let commit: String?
    /// The file's real size in bytes (`X-Linked-Size` / `Content-Length`).
    public let size: Int64?

    public init(etag: String?, commit: String?, size: Int64?) {
        self.etag = etag
        self.commit = commit
        self.size = size
    }

    /// Whether `etag` is a content SHA-256 (an LFS file we can verify against).
    public var etagIsSHA256: Bool {
        guard let etag, etag.count == 64 else { return false }
        return etag.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// HTTP seam: fetch bytes. `head` is used to size/verify; `download` streams to
/// a file, reporting cumulative bytes written.
public protocol ModelTransport: Sendable {
    func head(_ url: String) async throws -> RemoteFileInfo
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
    /// A file is not cached and the network is unavailable.
    case offlineAndMissing(String)
    /// A download completed but failed its size/hash integrity check.
    case integrityCheckFailed(String)
    /// A transport/HTTP or filesystem failure.
    case io(String)

    public var description: String {
        switch self {
        case let .offlineAndMissing(f): "\(f) is not downloaded and no network is available"
        case let .integrityCheckFailed(f): "integrity check failed for \(f)"
        case let .io(m): m
        }
    }
}
