/// One runtime artifact in a model distribution.
public struct ModelArtifact: Sendable, Equatable {
    /// Repo entry requested from the Hub. Directories end in `/`.
    public let entry: String
    /// Repo-relative path passed to the inference runtime after installation.
    public let path: String

    public init(entry: String, path: String? = nil) {
        self.entry = entry
        self.path = path ?? (entry.hasSuffix("/") ? String(entry.dropLast()) : entry)
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

/// A model's platform-independent Hub manifest.
///
/// Model packages declare their files once. Core selects the Apple artifact on
/// Core ML platforms and the portable artifact everywhere else, creates the
/// platform store, and performs wasm session setup when configured.
public struct ModelDistribution: Sendable, Equatable {
    public let repo: String
    public let revision: String
    public let sharedFiles: [String]
    public let appleArtifact: ModelArtifact?
    public let portableArtifact: ModelArtifact
    public let javaScriptSession: JavaScriptModelSession?

    public init(
        repo: String,
        revision: String,
        sharedFiles: [String],
        appleArtifact: ModelArtifact? = nil,
        portableArtifact: ModelArtifact,
        javaScriptSession: JavaScriptModelSession? = nil
    ) {
        self.repo = repo
        self.revision = revision
        self.sharedFiles = sharedFiles
        self.appleArtifact = appleArtifact
        self.portableArtifact = portableArtifact
        self.javaScriptSession = javaScriptSession
    }

    /// Download and verify this distribution using the current platform's
    /// transport and filesystem. Returns platform-neutral file access plus the
    /// selected inference artifact path.
    public func install(
        cacheDirectory: String? = nil,
        progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws -> InstalledModel {
        let store = try ModelStore.platformDefault(cacheDirectory: cacheDirectory)
        let artifact = selectedArtifact
        let spec = ModelSpec(
            repo: repo,
            revision: revision,
            files: [artifact.entry] + sharedFiles,
            cacheDirectory: cacheDirectory
        )
        let files = try await store.download(spec, progress: progress)
        #if os(WASI)
        if let javaScriptSession {
            try await files.initializeJSSession(
                artifact: artifact.path,
                hostGlobal: javaScriptSession.hostGlobal,
                method: javaScriptSession.method
            )
        }
        #endif
        return InstalledModel(files: files, artifactPath: files.path(artifact.path))
    }

    /// Verify an existing installation without network access.
    public func isInstalled(cacheDirectory: String? = nil) -> Bool {
        guard let store = try? ModelStore.platformDefault(cacheDirectory: cacheDirectory) else {
            return false
        }
        let artifact = selectedArtifact
        return store.isDownloaded(ModelSpec(
            repo: repo,
            revision: revision,
            files: [artifact.entry] + sharedFiles,
            cacheDirectory: cacheDirectory
        ))
    }

    private var selectedArtifact: ModelArtifact {
        #if canImport(CoreML)
        appleArtifact ?? portableArtifact
        #else
        portableArtifact
        #endif
    }
}

/// A verified local model installation.
public struct InstalledModel: Sendable {
    public let files: StoredModel
    public let artifactPath: String

    public init(files: StoredModel, artifactPath: String) {
        self.files = files
        self.artifactPath = artifactPath
    }
}
