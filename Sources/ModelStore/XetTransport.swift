// Apple-only transport that fetches weights over Hugging Face's Xet protocol
// instead of a single LFS stream: chunk-level deduplication against what the
// CAS already served plus parallel xorb fetches, which is several times faster
// on a first download of a large model and near-free on a revision bump that
// only moves a few chunks.
//
// `canImport(Xet)` is the whole gate. swift-xet is a *trait*-conditional package
// dependency restricted to Apple platforms in Package.swift (see the `Xet`
// trait there), so this file exists only in a graph that asked for it: a
// consumer without the trait, and every Linux/Android/wasm build, compiles the
// module exactly as before and keeps the URLSession path.
#if canImport(Xet)
import Foundation
import Xet

/// ``ModelTransport`` that downloads Xet-backed files through the CAS and falls
/// back to ``FoundationTransport`` for everything else.
///
/// The fallback is not only for small files. A repo that has not been migrated,
/// a mirror endpoint that serves plain LFS, and a CAS request that fails all
/// take it, so enabling the trait can make a download faster and cannot make it
/// impossible. The store verifies size and SHA-256 either way, so neither path
/// is trusted more than the other.
public final class XetTransport: ModelTransport {
    private let fallback = FoundationTransport()
    private let hubToken: String?
    private let session = DownloaderSession()

    /// - Parameter hubToken: Hub token for gated or private repos. `nil` reads
    ///   `HF_TOKEN` from the environment, matching the rest of the Hub tooling;
    ///   public repos need none.
    public init(hubToken: String? = nil) {
        let token = hubToken ?? ProcessInfo.processInfo.environment["HF_TOKEN"]
        self.hubToken = token.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func tree(_ url: String) async throws -> [RemoteEntry] { try await fallback.tree(url) }

    public func tags(_ url: String) async throws -> [String] { try await fallback.tags(url) }

    public func download(_ url: String, to destinationPath: String,
                         onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        guard let pointer = await pointer(for: url),
              let refreshURL = URL(string: pointer.refreshURL) else {
            try await fallback.download(url, to: destinationPath, onBytes: onBytes)
            return
        }
        let downloader = await session.downloader(refreshURL: refreshURL, hubToken: hubToken)
        // Callers require monotonic progress, and a poll already in flight when
        // the download finishes would otherwise report a stale, smaller size
        // after the final count.
        let reported = HighWaterMark(onBytes)
        do {
            let written = try await withProgressPolling(of: destinationPath, report: reported.report) {
                try await downloader.download(pointer.fileID, to: URL(fileURLWithPath: destinationPath))
            }
            reported.report(written)
        } catch is CancellationError {
            throw ModelStoreError.io("GET \(url): cancelled")
        } catch {
            // A CAS failure must not be a download failure: the file is still on
            // the Hub behind the ordinary redirect. It reports through the same
            // high-water mark, so restarting the file does not walk progress
            // backwards for whoever is watching.
            try await fallback.download(url, to: destinationPath, onBytes: reported.report)
        }
    }

    /// Releases the CAS connections once the store has finished a model. Each
    /// downloader owns an event-loop group and a pool of prewarmed connections,
    /// which is why one is kept across a model's files and why it must not
    /// outlive them.
    public func finishDownloads() async {
        await session.shutdown()
    }

    // MARK: internals

    /// `HEAD` the resolve URL without following the redirect, which is the only
    /// place the Hub states a file's CAS hash. Any failure here answers `nil`
    /// and the caller downloads the plain way.
    private func pointer(for url: String) async -> XetPointer? {
        guard let u = URL(string: url) else { return nil }
        var request = URLRequest(url: u)
        request.httpMethod = "HEAD"
        if let hubToken { request.setValue("Bearer \(hubToken)", forHTTPHeaderField: "Authorization") }
        guard let (_, response) = try? await URLSession.shared.data(for: request,
                                                                    delegate: NoRedirects()),
              let http = response as? HTTPURLResponse else { return nil }
        return XetPointer.from(
            xetHash: http.value(forHTTPHeaderField: "X-Xet-Hash"),
            link: http.value(forHTTPHeaderField: "Link"),
            resolveURL: url
        )
    }

    /// swift-xet reports no progress, so poll the file it is writing. 250 ms is
    /// well under the store's own reporting granularity and costs one `stat`.
    private func withProgressPolling<T>(
        of path: String,
        report: @escaping @Sendable (Int64) -> Void,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let poll = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 250_000_000)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let size = (attrs[.size] as? NSNumber)?.int64Value {
                    report(size)
                }
            }
        }
        defer { poll.cancel() }
        return try await body()
    }
}

/// Forwards only values greater than every value forwarded before it.
private final class HighWaterMark: @unchecked Sendable {
    private let lock = NSLock()
    private let onBytes: @Sendable (Int64) -> Void
    private var highest: Int64 = 0

    init(_ onBytes: @escaping @Sendable (Int64) -> Void) { self.onBytes = onBytes }

    var report: @Sendable (Int64) -> Void {
        { [self] bytes in
            let forward = lock.withLock { () -> Bool in
                guard bytes > highest else { return false }
                highest = bytes
                return true
            }
            if forward { onBytes(bytes) }
        }
    }
}

/// Holds one downloader per repo revision (the refresh URL identifies it) for as
/// long as the store is working through that model's files, so the token, the
/// event-loop group and the prewarmed connections are paid for once instead of
/// once per file.
private actor DownloaderSession {
    private var current: (refreshURL: URL, downloader: XetDownloader)?

    func downloader(refreshURL: URL, hubToken: String?) async -> XetDownloader {
        if let current, current.refreshURL == refreshURL { return current.downloader }
        await shutdown()
        let downloader = XetDownloader(refreshURL: refreshURL, hubToken: hubToken)
        current = (refreshURL, downloader)
        return downloader
    }

    func shutdown() async {
        guard let current else { return }
        self.current = nil
        try? await current.downloader.shutdown()
    }
}

/// Reading `X-Xet-Hash` means seeing the 302 itself, not the CDN response it
/// points at.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

public extension ModelStore {
    /// The Apple default when the `Xet` trait is enabled: CAS downloads with the
    /// URLSession path underneath them.
    static func acceleratedTransport() -> any ModelTransport { XetTransport() }
}
#endif
