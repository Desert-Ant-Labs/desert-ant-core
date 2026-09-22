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

    /// One delegate and one session for the whole process, shared by every
    /// download.
    ///
    /// Not a session per download closed with `finishTasksAndInvalidate()`:
    /// on corelibs-foundation (Linux and Windows) URLSession is libcurl-backed,
    /// and invalidating a session as its last task completes races the shared
    /// multi handle into "deallocated with non-zero retain count", which the
    /// runtime turns into an abort. It killed the process at the *end* of a
    /// successful download, having already written the file. A session that
    /// lives as long as the process is never torn down, so the race has no
    /// window -- and one connection pool serves every file instead of one per
    /// file. The cost is that the delegate is shared too, so a download's
    /// state hangs off its task rather than off the delegate.
    private static let downloadDelegate = DownloadDelegate()
    private static let downloadSession = URLSession(
        configuration: .default,
        delegate: FoundationTransport.downloadDelegate,
        delegateQueue: nil
    )

    public func download(_ url: String, to destinationPath: String, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        guard let u = URL(string: url) else { throw ModelStoreError.io("bad url: \(url)") }
        let http = try await withCheckedThrowingContinuation { (c: CheckedContinuation<HTTPURLResponse?, Error>) in
            let task = FoundationTransport.downloadSession.downloadTask(with: u)
            // Registered before `resume()`: the first callback can land as
            // soon as the task starts running.
            FoundationTransport.downloadDelegate.begin(
                task,
                destination: URL(fileURLWithPath: destinationPath),
                onBytes: onBytes,
                continuation: c
            )
            task.resume()
        }
        if let http, !(200..<300).contains(http.statusCode) {
            throw ModelStoreError.io("GET \(url): HTTP \(http.statusCode)")
        }
    }

    public func tags(_ url: String) async throws -> [String] {
        guard let u = URL(string: url) else { throw ModelStoreError.io("bad url: \(url)") }
        let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: u))
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelStoreError.io("refs \(url): HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        struct Refs: Decodable {
            struct Ref: Decodable { let name: String }
            let tags: [Ref]?
        }
        return try JSONDecoder().decode(Refs.self, from: data).tags?.map(\.name) ?? []
    }

    private struct TreeItem: Decodable {
        let type: String
        let path: String
        let size: Int64
        let lfs: LFS?
        struct LFS: Decodable { let oid: String }
    }

    /// Streams downloads to their destinations, reporting cumulative bytes via
    /// each one's `onBytes`. Resumes every continuation exactly once, in
    /// `didCompleteWithError`.
    ///
    /// One instance serves the shared session (see `downloadSession`), so the
    /// per-download state lives in a table keyed by `taskIdentifier` rather
    /// than in stored properties, and each callback looks its download up.
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        /// What one in-flight download needs to finish and report itself.
        private struct Pending {
            let destination: URL
            let onBytes: @Sendable (Int64) -> Void
            let continuation: CheckedContinuation<HTTPURLResponse?, Error>
            var moveError: Error?
            var lastReportedBytes: Int64 = 0
        }

        // URLSession calls the delegate on one serial queue, but `begin` runs
        // on whichever thread started the download, so the table needs a lock.
        private let lock = NSLock()
        private var pending: [Int: Pending] = [:]

        /// Registers a download. Call before `resume()`.
        func begin(_ task: URLSessionTask, destination: URL,
                   onBytes: @escaping @Sendable (Int64) -> Void,
                   continuation: CheckedContinuation<HTTPURLResponse?, Error>) {
            lock.lock()
            pending[task.taskIdentifier] = Pending(
                destination: destination, onBytes: onBytes, continuation: continuation
            )
            lock.unlock()
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            // URLSession reports every received chunk — tens of thousands for a
            // large weight file — and each report fans out through an actor hop
            // downstream (`LazyLoader` spawns a Task per callback), which floods
            // the actor badly enough that observers see only 0% and 100%.
            // 512 KB steps keep progress sub-percent-smooth for anything over
            // ~50 MB at a few hundred callbacks per file. The final bytes of a
            // file always report (completion also reports via the store's
            // per-file accounting), so nothing is lost for small files.
            lock.lock()
            guard var entry = pending[downloadTask.taskIdentifier],
                  totalBytesWritten - entry.lastReportedBytes >= 512 * 1024
                    || totalBytesWritten == totalBytesExpectedToWrite
            else { lock.unlock(); return }
            entry.lastReportedBytes = totalBytesWritten
            pending[downloadTask.taskIdentifier] = entry
            let onBytes = entry.onBytes
            lock.unlock()
            // Outside the lock: this fans out through an actor hop downstream,
            // and no delegate callback should wait on that.
            onBytes(totalBytesWritten)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            lock.lock()
            let destination = pending[downloadTask.taskIdentifier]?.destination
            lock.unlock()
            guard let destination else { return }
            // The move happens here, not in didCompleteWithError: URLSession
            // deletes the temporary file as soon as this returns.
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                lock.lock()
                pending[downloadTask.taskIdentifier]?.moveError = error
                lock.unlock()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.lock()
            let entry = pending.removeValue(forKey: task.taskIdentifier)
            lock.unlock()
            // Removed, so the continuation is resumed exactly once even if the
            // session reports a task twice.
            guard let entry else { return }
            if let error { entry.continuation.resume(throwing: error) }
            else if let moveError = entry.moveError { entry.continuation.resume(throwing: moveError) }
            else { entry.continuation.resume(returning: task.response as? HTTPURLResponse) }
        }
    }
}

/// `FileManager`-backed filesystem.

/// `autoreleasepool` where it exists, a plain call where it does not. The chunks
/// a streaming hash reads are autoreleased on Darwin, so without a pool per
/// iteration they stay live to the end of the loop and peak memory tracks the
/// file size regardless of the chunking.
@inline(__always)
func withReleasePool<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(ObjectiveC)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

public struct FoundationFileSystem: FileSystem {
    private let cacheRoot: String?

    /// - Parameter cacheRoot: base for the managed cache layout. `nil` asks
    ///   `FileManager` for the platform's caches directory.
    public init(cacheRoot: String? = nil) {
        self.cacheRoot = cacheRoot.flatMap { $0.isEmpty ? nil : $0 }
    }

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

    /// Hash in 1 MB chunks so peak memory does not track the file size.
    public func digest(_ path: String) throws -> (size: Int64, sha256: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw ModelStoreError.io("cannot open \(path)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        var done = false
        while !done {
            try withReleasePool {
                let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
                if chunk.isEmpty { done = true; return }
                total += Int64(chunk.count)
                chunk.withUnsafeBytes { raw in
                    hasher.update(raw.bindMemory(to: UInt8.self))
                }
            }
        }
        return (total, SHA256.hex(hasher.finalize()))
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

    public func listDirectory(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    public func defaultCacheRoot() -> String {
        if let cacheRoot { return cacheRoot }
        if let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            return url.path
        }
        // Fallback: NSHomeDirectory() is portable (homeDirectoryForCurrentUser is
        // macOS/Linux-only, unavailable on iOS/tvOS/watchOS).
        return NSHomeDirectory() + "/.cache"
    }
}

public extension StoredModel {
    static func platformLocal(rootPath: String) throws -> StoredModel {
        StoredModel(rootPath: rootPath, fileSystem: FoundationFileSystem())
    }
}

public extension ModelStore {
    /// Default Apple/Linux store: URLSession + FileManager, or the Xet
    /// transport where the `Xet` trait put it in the graph (Apple only; it keeps
    /// URLSession underneath as its fallback).
    ///
    /// - Parameter cacheRoot: base for the managed cache layout. `nil` uses the
    ///   platform caches directory, which is the usual case on Apple and Linux.
    init(cacheRoot: String? = nil, endpoint: String = "https://huggingface.co") {
        self.init(transport: ModelStore.platformTransport(),
                  fileSystem: FoundationFileSystem(cacheRoot: cacheRoot), endpoint: endpoint)
    }

    /// The best transport this build has. `canImport` rather than a platform
    /// check: the Xet module is in the graph only for an Apple build that
    /// enabled the trait (see XetTransport.swift).
    static func platformTransport() -> any ModelTransport {
        #if canImport(Xet)
        return acceleratedTransport()
        #else
        return FoundationTransport()
        #endif
    }

    /// An explicit `cacheRoot` wins; `nil` falls back to FileManager's caches
    /// directory. This used to discard `cacheRoot` outright, so a caller that
    /// passed one wrote somewhere else without saying so - which matters wherever
    /// the platform default is not writable.
    static func platformDefault(cacheRoot: String?) throws -> ModelStore {
        ModelStore(cacheRoot: cacheRoot)
    }
}
#endif
