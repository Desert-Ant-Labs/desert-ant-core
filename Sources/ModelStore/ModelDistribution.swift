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
    /// Repo-relative model file passed to the JavaScript session factory.
    public let modelPath: String
    public let hostGlobal: String
    public let method: String

    public init(
        modelPath: String,
        hostGlobal: String,
        method: String = "createSession"
    ) {
        self.modelPath = modelPath
        self.hostGlobal = hostGlobal
        self.method = method
    }
}

/// The complete file manifest for one platform.
public struct ModelPlatformFiles: Sendable, Equatable {
    /// Hub entries required on this platform. Directory entries end in `/`.
    public let files: [String]
    /// Optional wasm host-session setup. Ignored on non-web platforms.
    public let javaScriptSession: JavaScriptModelSession?

    public init(
        files: [String],
        javaScriptSession: JavaScriptModelSession? = nil
    ) {
        self.files = files
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

    /// Download and verify the current platform's complete file list, returning
    /// the cached model directory.
    public func install(
        cacheDirectory: String? = nil,
        progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws -> StoredModel {
        let platform = try requiredPlatformFiles()
        let store = try ModelStore.platformDefault(cacheDirectory: cacheDirectory)
        let spec = ModelSpec(
            repo: repo,
            revision: revision,
            files: platform.files,
            cacheDirectory: cacheDirectory
        )
        let files = try await store.download(spec, progress: progress)
        try await platform.startJavaScriptSession(with: files)
        return files
    }

    /// Use model files supplied in one local directory instead of downloading.
    /// The directory must contain the current platform's declared paths.
    public func load(from directory: String) async throws -> StoredModel {
        let platform = try requiredPlatformFiles()
        let files = try StoredModel.platformLocal(rootPath: directory)
        try files.requireFiles(platform.files)
        try await platform.startJavaScriptSession(with: files)
        return files
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
}

private extension ModelPlatformFiles {
    /// Start the wasm host inference session, if one is configured. A no-op on
    /// every non-web platform.
    func startJavaScriptSession(with files: StoredModel) async throws {
        #if os(WASI)
        guard let session = javaScriptSession else { return }
        try files.requireFiles([session.modelPath])
        try await files.initializeJSSession(
            artifact: session.modelPath,
            hostGlobal: session.hostGlobal,
            method: session.method
        )
        #endif
    }
}
