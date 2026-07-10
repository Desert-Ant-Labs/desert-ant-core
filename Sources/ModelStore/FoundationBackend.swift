// Apple/Linux backend for the ModelStore seams, using Foundation
// (URLSession + FileManager). This is the ONLY file in the module that imports
// Foundation; it is gated off Android and wasm, which supply host-backed
// transport/filesystem instead. So `import Foundation` never reaches those
// builds (no ICU on Android, no bloat on wasm).
#if canImport(Foundation) && !os(Android) && !os(WASI)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// `URLSession`-backed HTTP transport.
public struct FoundationTransport: ModelTransport {
    public init() {}

    public func tree(_ url: String) async throws -> [RemoteEntry] {
        guard let u = URL(string: url) else { throw ModelStoreError.io("bad url: \(url)") }
        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: u))
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelStoreError.io("tree \(url): HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let items = try JSONDecoder().decode([TreeItem].self, from: data)
        return items.compactMap { $0.type == "file" ? RemoteEntry(path: $0.path, size: $0.size, sha256: $0.lfs?.oid) : nil }
    }

    public func download(_ url: String, to destinationPath: String, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        guard let u = URL(string: url) else { throw ModelStoreError.io("bad url: \(url)") }
        let delegate = DownloadDelegate(destination: URL(fileURLWithPath: destinationPath), onBytes: onBytes)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let http = try await withCheckedThrowingContinuation { (c: CheckedContinuation<HTTPURLResponse?, Error>) in
            delegate.continuation = c
            session.downloadTask(with: u).resume()
        }
        if let http, !(200..<300).contains(http.statusCode) {
            throw ModelStoreError.io("GET \(url): HTTP \(http.statusCode)")
        }
    }

    private struct TreeItem: Decodable {
        let type: String
        let path: String
        let size: Int64
        let lfs: LFS?
        struct LFS: Decodable { let oid: String }
    }

    /// Streams a download to `destination`, reporting cumulative bytes via
    /// `onBytes`. Resumes the continuation once, in `didCompleteWithError`.
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let destination: URL
        let onBytes: @Sendable (Int64) -> Void
        var continuation: CheckedContinuation<HTTPURLResponse?, Error>?
        private var moveError: Error?

        init(destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) {
            self.destination = destination; self.onBytes = onBytes
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            onBytes(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch { moveError = error }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { continuation?.resume(throwing: error) }
            else if let moveError { continuation?.resume(throwing: moveError) }
            else { continuation?.resume(returning: task.response as? HTTPURLResponse) }
            continuation = nil
        }
    }
}

/// `FileManager`-backed filesystem.
public struct FoundationFileSystem: FileSystem {
    public init() {}

    public func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    public func size(_ path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        if let n = attrs[.size] as? NSNumber { return n.int64Value }
        if let i = attrs[.size] as? Int { return Int64(i) }
        return nil
    }

    public func read(_ path: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    public func write(_ path: String, _ bytes: [UInt8]) throws {
        try Data(bytes).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    public func move(_ from: String, to: String) throws {
        try? FileManager.default.removeItem(atPath: to)
        try FileManager.default.moveItem(atPath: from, toPath: to)
    }

    public func remove(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    public func defaultCacheRoot() -> String {
        if let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return url.path
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache").path
    }
}

public extension ModelStore {
    /// Default Apple/Linux store: URLSession + FileManager.
    init(endpoint: String = "https://huggingface.co") {
        self.init(transport: FoundationTransport(), fileSystem: FoundationFileSystem(), endpoint: endpoint)
    }

    static func platformDefault(cacheDirectory: String?) throws -> ModelStore {
        ModelStore()
    }
}
#endif
