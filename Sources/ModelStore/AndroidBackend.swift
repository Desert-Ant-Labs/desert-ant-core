// Android transport: the host (Kotlin, java.net/OkHttp) performs HTTP via the
// CHostBridge callbacks; Swift keeps the filesystem (POSIX) and verification.
// A runtime shim installs `host_set_http_head` / `host_set_http_download`.
#if os(Android)
import CHostBridge

public struct CHostBridgeTransport: ModelTransport {
    public init() {}

    public func head(_ url: String) async throws -> RemoteFileInfo {
        guard let raw = url.withCString({ host_http_head($0) }) else {
            throw ModelStoreError.io("HEAD \(url) (no host_http_head)")
        }
        defer { host_free(raw) }
        // "etag\ncommit\nsize"
        let lines = String(cString: raw).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func field(_ i: Int) -> String? { i < lines.count && !lines[i].isEmpty ? lines[i] : nil }
        return RemoteFileInfo(etag: field(0), commit: field(1), size: field(2).flatMap { Int64($0) })
    }

    public func download(_ url: String, to destinationPath: String, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let rc = url.withCString { u in destinationPath.withCString { d in host_http_download(u, d) } }
        guard rc == 0 else { throw ModelStoreError.io("GET \(url) failed on host") }
        // The store reads the file size for progress after this returns.
    }
}

public extension ModelStore {
    /// Default Android store: host HTTP (CHostBridge) + POSIX filesystem.
    /// - Parameter cacheRoot: the app's cache directory (from the host `Context`).
    init(cacheRoot: String, endpoint: String = "https://huggingface.co") {
        self.init(transport: CHostBridgeTransport(),
                  fileSystem: POSIXFileSystem(cacheRoot: cacheRoot), endpoint: endpoint)
    }
}
#endif
