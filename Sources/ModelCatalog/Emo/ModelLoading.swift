// How Emo obtains and shapes its model: the file manifest, the
// download/adopt sources, and the `ModelAssets` the pipeline consumes.
// (Running the model is `Model.swift`.) All platform variation is data here
// (which artifact ships where); building the platform's session is
// DesertAnt's `inferenceSession` factory.
import DesertAnt

// The SDK's usage identity (`EmoModel.sdkInfo`) is derived from the catalog
// declaration's `product` + `sdkVersion`, so it cannot drift from the published
// package version or be forgotten on a session.

// The model's file names, per-platform manifest, repo and pinned revision live
// in the monorepo catalog (`ModelCatalog/Emo/Emo.swift`) as `EmoModel`, so
// tooling and this SDK read one declaration.

/// Loaded model inputs: the sidecar metadata, the semantic tokenizer bytes, and
/// a ready inference session. Also the entry point for the cross-language
/// bindings and custom deployments (not part of the Swift SDK's public API,
/// which loads assets for you).
@_spi(EmoBindings)
public struct ModelAssets: Sendable {
    /// Contents of `emo_meta.json` (labels + featurizer/tokenizer constants).
    public let metaJSON: String
    /// Contents of `emo_tokenizer.bin` (the pruned-unigram semantic tokenizer).
    public let tokenizer: [UInt8]
    /// The platform's ready-to-run session for the model artifact.
    let session: any InferenceSession

    /// Bindings entry point: build from an already-constructed session (e.g. the
    /// wasm host's `JSInferenceSession`) plus the sidecars.
    @_spi(EmoBindings)
    public init(metaJSON: String, tokenizer: [UInt8], session: any InferenceSession) {
        self.metaJSON = metaJSON
        self.tokenizer = tokenizer
        self.session = session
    }

    /// Build from a resolved model directory: read the sidecars and let the core
    /// pick this platform's session for the artifact.
    static func emo(files: StoredModel) async throws -> ModelAssets {
        ModelAssets(
            metaJSON: try files.readString(EmoModel.meta),
            tokenizer: try files.read(EmoModel.tokenizer),
            session: try await files.inferenceSession(model: EmoModel.artifact, hostGlobal: EmoModel.hostGlobal, sdk: EmoModel.sdkInfo))
    }
}

public extension Emo {
    /// The published model repository.
    static var modelRepo: String { EmoModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { EmoModel.revision }

    /// Resolve the model for `directory` (adopt your files, or download there),
    /// then build loadable assets. `nil` uses the managed cache.
    internal static func resolvedAssets(
        directory: String?,
        cacheRoot: String? = nil,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> ModelAssets {
        let files = try await distribution().resolve(cacheDirectory: directory, cacheRoot: cacheRoot) { progress($0.fraction) }
        return try await .emo(files: files)
    }

    /// Whether the model is available offline for `directory`.
    internal static func isModelAvailable(directory: String?, cacheRoot: String? = nil) -> Bool {
        distribution().isAvailable(cacheDirectory: directory, cacheRoot: cacheRoot)
    }

    private static func distribution() -> ModelDistribution { EmoModel.distribution }
}

// MARK: shipping the model with your app

// This package bundles no model artifact and has no resource bundle to load
// one from. The model is downloaded on demand: to a managed cache location by
// default, or to the `directory` you pass. Shipping the model with your app is
// therefore just pointing `directory` at a folder that already holds this
// platform's artifact plus the sidecars - it is then used offline, with no
// download. (Android's equivalent is classpath resources, and wasm always
// downloads.)
