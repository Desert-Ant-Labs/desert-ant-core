// Android transport: the host (Kotlin, java.net/OkHttp) performs HTTP via the
// CHostBridge callbacks; Swift keeps the filesystem (POSIX) and verification.
// A runtime shim installs `host_set_http_head` / `host_set_http_download`.
#if os(Android)
import CHostBridge

public struct CHostBridgeTransport: ModelTransport {
    public init() {}

    public func tree(_ url: String) async throws -> [RemoteEntry] {
        guard let raw = url.withCString({ host_http_tree($0) }) else {
            throw ModelStoreError.io("tree \(url) (no host_http_tree)")
        }
        defer { host_free(raw) }
        // one file per line: "path\tsize\tsha256" (empty sha256 for non-LFS)
        var out: [RemoteEntry] = []
        for line in String(cString: raw).split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count == 3, let size = Int64(cols[1]) else { continue }
            out.append(RemoteEntry(path: String(cols[0]), size: size,
                                   sha256: cols[2].isEmpty ? nil : String(cols[2])))
        }
        return out
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
