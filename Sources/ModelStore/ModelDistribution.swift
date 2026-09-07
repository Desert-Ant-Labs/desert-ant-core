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

/// Which inference runtime opens a model's artifact.
public enum ModelRuntime: String, Sendable, Hashable, CaseIterable {
    case coreML = "coreml"
    case coreAI = "coreai"
    case liteRT = "litert"

    /// What this platform's `files` list is for: Core ML on Apple, LiteRT elsewhere.
    public static var platformDefault: ModelRuntime {
        ModelPlatform.current == .apple ? .coreML : .liteRT
    }

    /// The runtime this device should run: Core AI where the OS ships it, else the platform default.
    public static var current: ModelRuntime {
        #if canImport(CoreAI)
        if #available(macOS 27.0, iOS 27.0, tvOS 27.0, visionOS 27.0, watchOS 27.0, *) { return .coreAI }
        #endif
        return platformDefault
    }

    /// The runtime an artifact path is for, by its extension, or nil for an unknown one.
    public static func inferred(fromPath path: String) -> ModelRuntime? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if name.hasSuffix(".aimodel") { return .coreAI }
        if name.hasSuffix(".mlmodelc") || name.hasSuffix(".mlpackage") { return .coreML }
        if name.hasSuffix(".tflite") { return .liteRT }
        return nil
    }
}

/// A model's Hub declaration: the complete file list for each platform.
///
/// Each platform owns its own list, so artifacts and sidecars may differ
/// entirely. Core selects the current platform's list and handles download,
/// verification, caching, and local-directory validation. Turning a resolved
/// `StoredModel` into runtime assets is the model package's concern.
///
/// `runtimeFiles` lists a platform's alternate runtime, Core AI on Apple. It is
/// preferred where ``ModelRuntime/current`` names it, and `files` stands in when
/// it is missing or fails to load.
public struct ModelDistribution: Sendable, Equatable {
    public let repo: String
    public let revision: String
    /// Repo entries per platform. Directory entries end in `/`.
    public let files: [ModelPlatform: [String]]
    /// Repo entries for a runtime other than the platform's default.
    public let runtimeFiles: [ModelRuntime: [String]]

    public init(repo: String, revision: String, files: [ModelPlatform: [String]],
                runtimeFiles: [ModelRuntime: [String]] = [:]) {
        self.repo = repo
        self.revision = revision
        self.files = files
        self.runtimeFiles = runtimeFiles
    }

    /// The runtime this device opens: the current one when this model ships files for it.
    public var currentRuntime: ModelRuntime {
        runtimeFiles[.current] != nil ? .current : .platformDefault
    }

    /// The current platform's file list, or `nil` if unsupported.
    public var currentFiles: [String]? { runtimeFiles[.current] ?? files[.current] }

    /// Whether the current runtime is an alternate the platform default can stand in for.
    public var hasFallback: Bool { currentRuntime != .platformDefault && files[.current] != nil }

    /// The same slice of the repo on the platform's default runtime.
    public var platformDefault: ModelDistribution {
        ModelDistribution(repo: repo, revision: revision, files: files)
    }

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

    /// Directories of every downloaded version of this model's repo in the
    /// managed cache (see ``ModelStore/downloadedModels(repo:)``): one path per
    /// revision, its last component the revision itself.
    public func installedModels(cacheRoot: String? = nil) -> [String] {
        guard let store = try? ModelStore.platformDefault(cacheRoot: cacheRoot) else { return [] }
        return store.downloadedModels(repo: repo)
    }

    /// This distribution re-pointed at the concrete revision a
    /// ``RevisionRequirement`` resolves to (see
    /// ``ModelStore/resolveRevision(_:repo:)`` for the network/cache/fallback
    /// order). `exact` never touches the network.
    public func resolving(_ requirement: RevisionRequirement, cacheRoot: String? = nil) async -> ModelDistribution {
        if let revision = requirement.exactRevision {
            return ModelDistribution(repo: repo, revision: revision, files: files, runtimeFiles: runtimeFiles)
        }
        guard let store = try? ModelStore.platformDefault(cacheRoot: cacheRoot) else { return self }
        let revision = await store.resolveRevision(requirement, repo: repo)
        return ModelDistribution(repo: repo, revision: revision, files: files, runtimeFiles: runtimeFiles)
    }

    /// The downloaded revisions of this repo satisfying `requirement` (offline;
    /// the managed cache only). The best match is last-sorted by the
    /// requirement's own ordering via ``RevisionRequirement/bestMatch(in:)``.
    public func downloadedRevisions(satisfying requirement: RevisionRequirement,
                                    cacheRoot: String? = nil) -> [String] {
        guard let store = try? ModelStore.platformDefault(cacheRoot: cacheRoot) else { return [] }
        return store.downloadedRevisions(repo: repo).filter { requirement.bestMatch(in: [$0]) != nil }
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
        guard hasFallback else {
            return try await install(cacheDirectory: cacheDirectory, cacheRoot: cacheRoot, progress: progress)
        }
        // The alternate runtime's files are preferred, and the platform default's stand in when
        // they are not in `cacheDirectory` or not in the repo at this revision.
        if let placed = platformDefault.userPlacedFiles(cacheDirectory) { return placed }
        do {
            return try await install(cacheDirectory: cacheDirectory, cacheRoot: cacheRoot, progress: progress)
        } catch {
            return try await platformDefault.install(cacheDirectory: cacheDirectory, cacheRoot: cacheRoot,
                                                     progress: progress)
        }
    }

    /// The runtime `files` (from ``resolve``) will open: the alternate when its entries are all
    /// there, else the platform default.
    public func runtime(of files: StoredModel) -> ModelRuntime {
        guard hasFallback, let alternate = runtimeFiles[.current] else { return currentRuntime }
        return (try? files.requireFiles(alternate)) != nil ? .current : .platformDefault
    }

    /// Whether the model is available offline for `cacheDirectory`: files you
    /// placed there, or our verified cache. An interrupted download is not.
    public func isAvailable(cacheDirectory: String? = nil, cacheRoot: String? = nil) -> Bool {
        userPlacedFiles(cacheDirectory) != nil || isInstalled(cacheDirectory: cacheDirectory, cacheRoot: cacheRoot)
            || (hasFallback && platformDefault.isAvailable(cacheDirectory: cacheDirectory, cacheRoot: cacheRoot))
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
