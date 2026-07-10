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

/// JavaScript session factory used by wasm inference runtimes.
public struct JavaScriptModelSession: Sendable, Equatable {
    public let hostGlobal: String
    public let method: String

    public init(hostGlobal: String, method: String = "createSession") {
        self.hostGlobal = hostGlobal
        self.method = method
    }
}

/// The complete file manifest and runtime artifact for one platform.
public struct ModelPlatformFiles: Sendable, Equatable {
    /// Hub entries required on this platform. Directory entries end in `/`.
    public let files: [String]
    /// Repo-relative artifact passed to the platform inference runtime.
    public let artifactPath: String
    /// Optional wasm host-session setup. Ignored on non-web platforms.
    public let javaScriptSession: JavaScriptModelSession?

    public init(
        files: [String],
        artifactPath: String,
        javaScriptSession: JavaScriptModelSession? = nil
    ) {
        self.files = files
        self.artifactPath = artifactPath
        self.javaScriptSession = javaScriptSession
    }
}

/// A model's platform-independent Hub declaration.
///
/// Each platform owns its complete file list, so artifacts and sidecars may be
/// entirely different. Core selects the current list and handles download,
/// verification, caching, local-directory validation, and wasm session setup.
public struct ModelDistribution: Sendable, Equatable {
    public let repo: String
    public let revision: String
    public let platforms: [ModelPlatform: ModelPlatformFiles]

    public init(
        repo: String,
        revision: String,
        platforms: [ModelPlatform: ModelPlatformFiles]
    ) {
        self.repo = repo
        self.revision = revision
        self.platforms = platforms
    }

    public var currentPlatformFiles: ModelPlatformFiles? {
        platforms[.current]
    }

    /// Download and verify the current platform's complete file list.
    public func install(
        cacheDirectory: String? = nil,
        progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws -> InstalledModel {
        let platform = try requiredPlatformFiles()
        let store = try ModelStore.platformDefault(cacheDirectory: cacheDirectory)
        let spec = ModelSpec(
            repo: repo,
            revision: revision,
            files: platform.files,
            cacheDirectory: cacheDirectory
        )
        let files = try await store.download(spec, progress: progress)
        try await initializeJavaScriptSession(platform, files: files)
        return InstalledModel(files: files, artifactPath: files.path(platform.artifactPath))
    }

    /// Use model files supplied in one local directory instead of downloading.
    /// The directory must contain the current platform's declared paths.
    public func load(from directory: String) async throws -> InstalledModel {
        let platform = try requiredPlatformFiles()
        let files = try StoredModel.platformLocal(rootPath: directory)
        for entry in platform.files {
            let relativePath = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            guard files.exists(relativePath) else {
                throw ModelStoreError.localFileMissing(files.path(relativePath))
            }
        }
        let installed = InstalledModel(files: files, artifactPath: files.path(platform.artifactPath))
        try await initializeJavaScriptSession(platform, files: files)
        return installed
    }

    /// Verify an existing cached installation without network access.
    public func isInstalled(cacheDirectory: String? = nil) -> Bool {
        guard let platform = currentPlatformFiles,
              let store = try? ModelStore.platformDefault(cacheDirectory: cacheDirectory) else {
            return false
        }
        return store.isDownloaded(ModelSpec(
            repo: repo,
            revision: revision,
            files: platform.files,
            cacheDirectory: cacheDirectory
        ))
    }

    private func requiredPlatformFiles() throws -> ModelPlatformFiles {
        guard let files = currentPlatformFiles else {
            throw ModelStoreError.unsupportedPlatform(ModelPlatform.current.rawValue)
        }
        return files
    }

    private func initializeJavaScriptSession(
        _ platform: ModelPlatformFiles,
        files: StoredModel
    ) async throws {
        #if os(WASI)
        if let session = platform.javaScriptSession {
            try await files.initializeJSSession(
                artifact: platform.artifactPath,
                hostGlobal: session.hostGlobal,
                method: session.method
            )
        }
        #endif
    }
}

/// A verified downloaded model or validated local model directory.
public struct InstalledModel: Sendable {
    public let files: StoredModel
    public let artifactPath: String

    public init(files: StoredModel, artifactPath: String) {
        self.files = files
        self.artifactPath = artifactPath
    }
}
