import DesertAnt

/// The sidecar metadata, the semantic tokenizer bytes, and a ready inference
/// session. The entry point for custom deployments; the public Swift API loads
/// assets itself.
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
            session: try await files.inferenceSession(model: EmoModel.artifact, sdk: EmoModel.sdkInfo))
    }
}

public extension Emo {
    /// The published model repository.
    static var modelRepo: String { EmoModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { EmoModel.revision }
}
