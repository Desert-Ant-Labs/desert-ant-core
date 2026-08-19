// How Gist obtains and shapes its model: the file manifest, the download/adopt
// sources, and the `ModelAssets` the pipeline consumes. (Running the model is
// `Model.swift`.) All platform variation is data here (which artifact ships
// where); building the platform's session is DesertAnt's `inferenceSession`
// factory.
import DesertAnt

// The SDK's usage identity (`GistModel.sdkInfo`) is derived from the catalog
// declaration's `product` + `sdkVersion`, so it cannot drift from the published
// package version or be forgotten on a session.

// The model's file names, per-platform manifest, repo and pinned revision live
// in the monorepo catalog (`Sources/Gist/Catalog.swift`) as `GistModel`, and the
// per-variant slices in `Variant.swift`, so tooling and this SDK read one
// declaration.

/// Loaded model inputs: the sidecar files, the embedding table, and a ready
/// inference session. Also the entry point for the cross-language bindings and
/// custom deployments (not part of the Swift SDK's public API, which loads
/// assets for you).
@_spi(GistBindings)
public struct ModelAssets: Sendable {
    /// Contents of `gist_tokenizer.bin` (the pruned-unigram semantic tokenizer).
    public let tokenizer: [UInt8]
    /// The quantized potion embedding table.
    public let embedding: [UInt8]
    /// Contents of `gist_embedding.json` (the table's shape and scale).
    public let embeddingMetaJSON: String
    /// Contents of `gist_config.json` (featurizer/head constants).
    public let configJSON: String
    /// Contents of `taxonomy.json` (slug -> display name).
    public let taxonomyJSON: String
    /// The platform's ready-to-run session for the model artifact.
    let session: any InferenceSession

    /// Bindings entry point: build from an already-constructed session (e.g. the
    /// wasm host's `JSInferenceSession`) plus the sidecars.
    @_spi(GistBindings)
    public init(tokenizer: [UInt8], embedding: [UInt8], embeddingMetaJSON: String,
                configJSON: String, taxonomyJSON: String, session: any InferenceSession) {
        self.tokenizer = tokenizer
        self.embedding = embedding
        self.embeddingMetaJSON = embeddingMetaJSON
        self.configJSON = configJSON
        self.taxonomyJSON = taxonomyJSON
        self.session = session
    }

    /// Build from a resolved model directory: read the sidecars and let the core
    /// pick this platform's session for the artifact. `variant` selects the
    /// subfolder its files were fetched into (`""` multilingual, `"en/"` English).
    static func gist(files: StoredModel, variant: GistVariant) async throws -> ModelAssets {
        ModelAssets(
            tokenizer: try files.read(variant.tokenizer),
            embedding: try files.read(variant.embedding),
            embeddingMetaJSON: try files.readString(variant.embeddingMeta),
            configJSON: try files.readString(variant.config),
            taxonomyJSON: try files.readString(variant.taxonomy),
            session: try await files.inferenceSession(model: variant.artifact, sdk: GistModel.sdkInfo))
    }
}

public extension Gist {
    /// The published model repository.
    static var modelRepo: String { GistModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    /// Holds both variants: multilingual at the repo root, English under `en/`.
    static var modelRevision: String { GistModel.revision }
}

// MARK: shipping the model with your app

// This package bundles no model artifact and has no resource bundle to load one
// from. The model is downloaded on demand: to a managed cache location by
// default, or to the `directory` you pass. Shipping the model with your app is
// therefore just pointing `directory` at a folder that already holds this
// platform's artifact plus the sidecars - it is then used offline, with no
// download. (Android's equivalent is classpath resources, and wasm always
// downloads.)
