import DesertAnt

/// A ready inference session for the classifier. The entry point for custom
/// deployments; the public Swift API loads the model itself.
@_spi(ModeratorBindings)
public struct ModelAssets: Sendable {
    let session: any InferenceSession

    /// Bindings entry point: build from an already-constructed session (e.g.
    /// the wasm host's `JSInferenceSession`).
    @_spi(ModeratorBindings)
    public init(session: any InferenceSession) {
        self.session = session
    }

    /// Build from a resolved model directory: this platform's session over the
    /// artifact.
    static func moderator(files: StoredModel) async throws -> ModelAssets {
        ModelAssets(session: try await files.inferenceSession(
            model: ModeratorModel.artifact, sdk: ModeratorModel.sdkInfo))
    }
}

public extension Moderator {
    /// The published model repository.
    static var modelRepo: String { ModeratorModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { ModeratorModel.revision }
}
