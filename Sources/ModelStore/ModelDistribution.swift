/// Runtime platforms that can have independent model file manifests.
public enum ModelPlatform: String, Sendable, Hashable, CaseIterable {
    case apple
    case android
    case linux
    case windows
    case web

    public static var current: ModelPlatform {
        #if os(WASI)
        .web
        #elseif os(Android)
        .android
        #elseif os(Linux)
        .linux
        #elseif os(Windows)
        .windows
        #else
        .apple
        #endif
    }
}

/// A model's Hub declaration: the complete file list for each platform.
///
/// Each platform owns its own list, so artifacts and sidecars may differ
/// entirely. Core selects the current platform's list and handles download,
/// verification, caching, and local-directory validation. Turning a resolved
/// `StoredModel` into runtime assets is the model package's concern.
public struct ModelDistribution: Sendable, Equatable {
    public let repo: String
    public let revision: String
    /// Repo entries per platform. Directory entries end in `/`.
    public let files: [ModelPlatform: [String]]

    public init(repo: String, revision: String, files: [ModelPlatform: [String]]) {
        self.repo = repo
        self.revision = revision
        self.files = files
    }

    /// The current platform's file list, or `nil` if unsupported.
    public var currentFiles: [String]? { files[.current] }

    /// Download and verify the current platform's file list, returning the
    /// cached model directory. A no-op (no network) once cached.
    /// - Parameter cacheDirectory: an explicit directory for this model's files
    ///   (direct layout), or `nil` for the managed nested layout.
    /// - Parameter cacheRoot: the platform base under which the managed layout
    ///   lives (the app cache dir on Android, node `~/.cache` on the web).
    ///   Ignored on Apple/Linux, where FileManager supplies a per-app base.
    public func install(
        cacheDirectory: String? = nil,
        cacheRoot: String? = nil,
        progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws -> StoredModel {
        _ = try requiredFiles()
        let store = try ModelStore.platformDefault(cacheRoot: cacheRoot)
        return try await store.download(spec(cacheDirectory), progress: progress)
    }

    /// Adopt model files from one local directory instead of downloading. The
    /// directory must contain the current platform's declared paths.
    public func load(from directory: String) throws -> StoredModel {
        let files = try StoredModel.platformLocal(rootPath: directory)
        try files.requireFiles(try requiredFiles())
        return files
    }

    /// Whether the current platform's files are cached and intact (offline).
    public func isInstalled(cacheDirectory: String? = nil, cacheRoot: String? = nil) -> Bool {
        guard currentFiles != nil,
              let store = try? ModelStore.platformDefault(cacheRoot: cacheRoot) else {
            return false
        }
        return store.isDownloaded(spec(cacheDirectory))
    }

    /// Get the model for `cacheDirectory`, downloading it there on demand. Files
    /// you placed there yourself are adopted offline; our own cache is reused
    /// offline; otherwise the model is downloaded. `nil` uses the managed cache.
    /// This is the one call a model SDK needs to obtain its files.
    public func resolve(
        cacheDirectory: String? = nil,
        cacheRoot: String? = nil,
        progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws -> StoredModel {
        if let placed = userPlacedFiles(cacheDirectory) { return placed }
        return try await install(cacheDirectory: cacheDirectory, cacheRoot: cacheRoot, progress: progress)
    }

    /// Whether the model is available offline for `cacheDirectory`: files you
    /// placed there, or our verified cache. An interrupted download is not.
    public func isAvailable(cacheDirectory: String? = nil, cacheRoot: String? = nil) -> Bool {
        userPlacedFiles(cacheDirectory) != nil || isInstalled(cacheDirectory: cacheDirectory, cacheRoot: cacheRoot)
    }

    /// Files present in `cacheDirectory` that you provided (no in-progress
    /// download bookkeeping), or `nil`. A `\(ModelStore.metadataDirectory)`
    /// marker means the location is download-managed, so its validity is gated
    /// by the verified manifest rather than mere file existence.
    private func userPlacedFiles(_ cacheDirectory: String?) -> StoredModel? {
        guard let cacheDirectory, let files = try? load(from: cacheDirectory),
              !files.exists(ModelStore.metadataDirectory) else { return nil }
        return files
    }

    private func requiredFiles() throws -> [String] {
        guard let files = currentFiles else {
            throw ModelStoreError.unsupportedPlatform(ModelPlatform.current.rawValue)
        }
        return files
    }

    private func spec(_ cacheDirectory: String?) -> ModelSpec {
        ModelSpec(
            repo: repo,
            revision: revision,
            files: currentFiles ?? [],
            cacheDirectory: cacheDirectory
        )
    }
}
