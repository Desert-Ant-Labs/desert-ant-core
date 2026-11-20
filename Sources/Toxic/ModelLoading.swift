import DesertAnt

/// The sidecar files plus a ready inference session. The entry point for custom deployments; the public Swift
/// API loads assets itself.
@_spi(ToxicBindings)
public struct ModelAssets: Sendable {
    /// Contents of the platform's `toxic_meta.json`.
    public let metaJSON: String
    /// Contents of `toxic_tokenizer.bin`.
    public let tokenizer: [UInt8]
    /// Contents of `toxic_table.bin`, the rows the graph's embeddings come from.
    public let table: [UInt8]
    /// The platform's ready-to-run session for the graph.
    let session: any InferenceSession

    /// Bindings entry point: build from an already-constructed session (the wasm host's `JSInferenceSession`)
    /// plus the sidecars.
    @_spi(ToxicBindings)
    public init(metaJSON: String, tokenizer: [UInt8], table: [UInt8], session: any InferenceSession) {
        self.metaJSON = metaJSON
        self.tokenizer = tokenizer
        self.table = table
        self.session = session
    }

    /// Build from a resolved model directory: read the sidecars and open this platform's session on the
    /// requested compute units.
    static func toxic(files: StoredModel, computeUnits: ComputeUnits) async throws -> ModelAssets {
        ModelAssets(
            metaJSON: try files.readString(ToxicModel.meta(for: .current)),
            tokenizer: try files.read(ToxicModel.tokenizer),
            table: try files.read(ToxicModel.table),
            // fp32 on a GPU: at fp16, even with fp32 accumulation, an Adreno GPU
            // (Nothing Phone 3, Android 16) scored a golden text's race head 0.54
            // where the reference says 0.28.
            session: try await files.inferenceSession(
                model: ToxicModel.artifact, computeUnits: computeUnits, gpuPrecision: .fp32,
                sdk: ToxicModel.sdkInfo))
    }
}

public extension Toxic {
    /// The published model repository.
    static var modelRepo: String { ToxicModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { ToxicModel.revision }
}
