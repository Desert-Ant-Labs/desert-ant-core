// How Redact obtains and shapes its model: the file manifest, the
// download/adopt sources, and the `ModelAssets` the pipeline consumes.
// (Running the model is `Model.swift`.) All platform variation is data here
// (which artifact ships where); building the platform's session is
// DesertAnt's `inferenceSession` factory.
import DesertAnt

// The model's file names, per-platform manifest, repo and pinned revision live
// in the monorepo catalog (`ModelCatalog/Redact/Redact.swift`) as `RedactModel`,
// so tooling and this SDK read one declaration. The same declaration derives the
// SDK's usage identity (`RedactModel.sdkInfo`), which every session below is
// built with so inference attributes to Redact rather than to the core.

/// Loaded model inputs: the sidecar files plus a ready inference session. Also
/// the entry point for the cross-language bindings and custom deployments (not
/// part of the Swift SDK's public API, which loads assets for you).
@_spi(RedactBindings)
public struct ModelAssets: Sendable {
    /// Contents of `redact_tokenizer.bin` (compact SentencePiece vocab).
    public let tokenizer: [UInt8]
    /// Contents of `labels.json` (BIOES id->label map).
    public let labelsJSON: String
    /// The platform's ready-to-run session for the model artifact.
    let session: any InferenceSession

    /// Bindings entry point: build from an already-constructed session (e.g. the
    /// wasm host's `JSInferenceSession`) plus the sidecars.
    @_spi(RedactBindings)
    public init(tokenizer: [UInt8], labelsJSON: String, session: any InferenceSession) {
        self.tokenizer = tokenizer
        self.labelsJSON = labelsJSON
        self.session = session
    }

    /// Build from a resolved model directory: read the sidecars and let the
    /// core pick this platform's session for the artifact.
    static func redact(files: StoredModel) async throws -> ModelAssets {
        ModelAssets(
            tokenizer: try files.read(RedactModel.tokenizer),
            labelsJSON: try files.readString(RedactModel.labels),
            session: try await files.inferenceSession(
                model: RedactModel.artifact, hostGlobal: RedactModel.hostGlobal, sdk: RedactModel.sdkInfo))
    }
}

public extension Redact {
    /// The published model repository.
    static var modelRepo: String { RedactModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { RedactModel.revision }
}

// MARK: shipping the model with your app

// This package bundles no model artifact and has no resource bundle to load
// one from. The model is downloaded on demand: to a managed cache location by
// default, or to the `directory` you pass. Shipping the model with your app is
// therefore just pointing `directory` at a folder that already holds this
// platform's artifact plus the sidecars - it is then used offline, with no
// download. (Android's equivalent is classpath resources, and wasm always
// downloads.)
