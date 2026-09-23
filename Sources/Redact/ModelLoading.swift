import DesertAnt

/// The sidecar files plus a ready inference session. The entry point for custom
/// deployments; the public Swift API loads assets itself.
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
                model: RedactModel.artifact, sdk: RedactModel.sdkInfo))
    }
}

public extension Redact {
    /// The published model repository.
    static var modelRepo: String { RedactModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { RedactModel.revision }
}
