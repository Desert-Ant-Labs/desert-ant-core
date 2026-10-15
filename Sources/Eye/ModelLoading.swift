import DesertAnt

/// The decoded sidecar and one ready session per function. The entry point for
/// custom deployments; the public Swift API loads assets itself.
@_spi(EyeBindings)
public struct ModelAssets: Sendable {
    let sessions: [String: any InferenceSession]
    let meta: Meta

    /// Bindings entry point: build from already-constructed sessions (one per
    /// function in ``EyeModel``, e.g. the wasm host's) plus the sidecar bytes.
    @_spi(EyeBindings)
    public init(sessions: [String: any InferenceSession], meta: [UInt8]) throws {
        self.sessions = sessions
        self.meta = try Meta(json: meta)
    }

    /// Build from a resolved model directory: the sidecar, and this platform's
    /// session for each function of the one artifact.
    static func eye(files: StoredModel) async throws -> ModelAssets {
        try ModelAssets(
            sessions: try await files.inferenceSessions(model: EyeModel.artifact, functions: EyeModel.functions,
                                                        sdk: EyeModel.sdkInfo),
            meta: try files.read(EyeModel.meta))
    }
}

public extension Eye {
    /// The published model repository.
    static var modelRepo: String { EyeModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { EyeModel.revision }
}
