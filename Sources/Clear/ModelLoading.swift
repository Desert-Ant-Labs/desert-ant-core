// How Clear obtains and shapes its model: the download/adopt sources and the
// `ModelAssets` the pipeline consumes. (Running the model is `Enhancer.swift`.)
// All platform variation is data (which artifact ships where, declared in
// `Catalog.swift`); building the platform's session is DesertAnt's
// `inferenceSession` factory - Core ML on Apple, LiteRT on Android/Linux, the JS
// host on the web.
import DesertAnt

// The SDK's usage identity (`ClearModel.sdkInfo`) is derived from the catalog
// declaration's `product` + `sdkVersion`, so it cannot drift from the published
// package version or be forgotten on a session.

/// Ready inference sessions for the enhancement model. A pool (one per worker)
/// lets the chunk loop use multiple cores on native platforms; usually one.
///
/// Also the entry point for the cross-language bindings and custom deployments
/// (not part of the Swift SDK's public API, which loads the model for you).
@_spi(ClearBindings)
public struct ModelAssets: Sendable {
    let sessions: [any InferenceSession]
    /// Which published variant these sessions run, reported on `Result`. Nil
    /// when the artifact is not a published variant (a custom export, or a
    /// wasm host that compiled the model itself).
    let variant: ModelVariant?
    /// The repo revision the sessions' artifact was resolved from, reported on
    /// `Result`. Nil for a local `modelPath`, explicit assets, or a wasm host
    /// (nothing was downloaded, so no revision applies).
    let revision: String?

    init(sessions: [any InferenceSession], variant: ModelVariant? = nil, revision: String? = nil) {
        self.sessions = sessions
        self.variant = variant
        self.revision = revision
    }

    /// Bindings entry point: build from an already-constructed session (e.g. the
    /// wasm host's `JSInferenceSession`), whose variant only the host knows.
    @_spi(ClearBindings)
    public init(session: any InferenceSession, variant: ModelVariant? = nil) {
        self.init(sessions: [session], variant: variant)
    }

    /// Sessions over an artifact already on disk. The variant is read off the
    /// file name, so a pre-downloaded artifact still identifies itself on
    /// `Result`.
    init(modelPath: String, computeUnits: ComputeUnits = .all, concurrency: Int = 1) throws {
        self.init(
            sessions: try (0..<max(1, concurrency)).map { _ in
                try inferenceSession(modelPath: modelPath, computeUnits: computeUnits, sdk: ClearModel.sdkInfo)
            },
            variant: ModelVariant.inferred(fromPath: modelPath))
    }

    /// Build from a resolved model directory: one session per worker over this
    /// platform's artifact.
    static func clear(files: StoredModel, variant: ModelVariant, revision: String? = nil,
                      computeUnits: ComputeUnits, concurrency: Int) async throws -> ModelAssets {
        var sessions: [any InferenceSession] = []
        for _ in 0..<max(1, concurrency) {
            sessions.append(try await files.inferenceSession(
                model: variant.artifact,
                computeUnits: computeUnits, sdk: ClearModel.sdkInfo))
        }
        return ModelAssets(sessions: sessions, variant: variant, revision: revision)
    }
}

public extension Clear {
    /// The published model repository.
    static var modelRepo: String { ClearModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { ClearModel.revision }
}

// MARK: shipping the model with your app

// This package bundles no model artifact and has no resource bundle to load one
// from. The model is downloaded on demand: to a managed cache location by
// default, or to the `directory` you pass. Shipping the model with your app is
// therefore just pointing `directory` at a folder that already holds this
// platform's artifact - it is then used offline, with no download. (Android's
// equivalent is classpath resources, and wasm always downloads.)
