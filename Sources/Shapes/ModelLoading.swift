// How Shapes obtains and shapes its model: the file manifest, the
// download/adopt sources, and the `ModelAssets` the recognizer consumes.
// (Running the model is `Model.swift`.) All platform variation is data here
// (which artifact ships where); building the platform's session is
// DesertAnt's `inferenceSession` factory.
import DesertAnt

// The SDK's usage identity (`ShapesModel.sdkInfo`) is derived from the catalog
// declaration's `product` + `sdkVersion`, so it cannot drift from the published
// package version or be forgotten on a session.

// The model's file names, per-platform manifest, repo and pinned revision live
// in the catalog declaration (`Catalog.swift`) as `ShapesModel`, so tooling and
// this SDK read one declaration.

/// Loaded model inputs: the sidecar metadata plus a ready inference session.
/// Also the entry point for the cross-language bindings and custom deployments
/// (not part of the Swift SDK's public API, which loads assets for you).
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

// MARK: shipping the model with your app

// This package bundles no model artifact and has no resource bundle to load one
// from. The model is downloaded on demand: to a managed cache location by
// default, or to the `directory` you pass. Shipping the model with your app is
// therefore just pointing `directory` at a folder that already holds this
// platform's artifact plus the sidecar - it is then used offline, with no
// download. (Android's equivalent is classpath resources, and wasm always
// downloads.)
