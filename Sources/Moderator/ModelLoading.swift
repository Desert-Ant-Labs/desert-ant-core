// How Moderator obtains its model: the `ModelAssets` the pipeline consumes.
// (Running the model is `Model.swift`.) All platform variation is data here
// (which artifact ships where, in `Catalog.swift`); building the platform's
// session is DesertAnt's `inferenceSession` factory.
import DesertAnt

/// A ready inference session for the classifier. Also the entry point for the
/// cross-language bindings and custom deployments (not part of the Swift SDK's
/// public API, which loads the model for you).
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

// MARK: shipping the model with your app

// This package bundles no model artifact. The model is downloaded on demand: to
// a managed cache location by default, or to the `directory` you pass. Shipping
// the model with your app is pointing `directory` at a folder that already holds
// this platform's artifact; it is then used offline, with no download.
