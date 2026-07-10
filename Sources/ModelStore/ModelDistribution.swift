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
    public func install(
        cacheDirectory: String? = nil,
        progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws -> StoredModel {
        _ = try requiredFiles()
        let store = try ModelStore.platformDefault(cacheDirectory: cacheDirectory)
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
    public func isInstalled(cacheDirectory: String? = nil) -> Bool {
        guard currentFiles != nil,
              let store = try? ModelStore.platformDefault(cacheDirectory: cacheDirectory) else {
            return false
        }
        return store.isDownloaded(spec(cacheDirectory))
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
