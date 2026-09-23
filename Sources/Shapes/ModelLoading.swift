import DesertAnt

/// The sidecar metadata plus a ready inference session. The entry point for
/// custom deployments; the public Swift API loads assets itself.
@_spi(ShapesBindings)
public struct ModelAssets: Sendable {
    /// Contents of `shapes_meta.json` (classes, gates, preprocessing constants).
    public let metaJSON: String
    /// The platform's ready-to-run session for the model artifact.
    let session: any InferenceSession

    /// Bindings entry point: build from an already-constructed session (e.g. the
    /// wasm host's `JSInferenceSession`) plus the sidecar.
    @_spi(ShapesBindings)
    public init(metaJSON: String, session: any InferenceSession) {
        self.metaJSON = metaJSON
        self.session = session
    }

    /// Build from a resolved model directory: read the sidecar and let the core
    /// pick this platform's session for the artifact.
    static func shapes(files: StoredModel) async throws -> ModelAssets {
        ModelAssets(
            metaJSON: try files.readString(ShapesModel.meta),
            session: try await files.inferenceSession(
                model: ShapesModel.artifact, sdk: ShapesModel.sdkInfo))
    }
}

public extension Shapes {
    /// The published model repository.
    static var modelRepo: String { ShapesModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { ShapesModel.revision }
}
