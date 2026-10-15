import DesertAnt

/// The sidecar files and the ready inference sessions, one per graph. The entry
/// point for custom deployments; the public Swift API loads assets itself.
@_spi(WhoBindings)
public struct ModelAssets: Sendable {
    /// Contents of `who_meta.json`: the filterbank geometry, every graph's shape and tensor names, the decision rule.
    public let metaJSON: String
    /// Contents of `who_mel_banks.f32`: `[mels, bins]` header then the table.
    public let melBanks: [UInt8]
    /// Contents of `who_voice_banks.f32`, the voice graph's filters in the same format.
    public let voiceBanks: [UInt8]
    /// Contents of `who_embed.f16`, the embedding layer the voices go through.
    public let embedding: [UInt8]
    /// The sessions by graph name (`encoder_<frames>`, `queries_<frames>`, `voice_<frames>`).
    let sessions: [String: any InferenceSession]

    @_spi(WhoBindings)
    public init(metaJSON: String, melBanks: [UInt8], voiceBanks: [UInt8], embedding: [UInt8], sessions: [String: any InferenceSession]) {
        self.metaJSON = metaJSON
        self.melBanks = melBanks
        self.voiceBanks = voiceBanks
        self.embedding = embedding
        self.sessions = sessions
    }

    /// Read the sidecars and open one session per graph on the requested compute units.
    static func who(files: StoredModel, variant: ModelVariant, computeUnits: ComputeUnits) async throws -> ModelAssets {
        guard variant.isAvailable(on: .current) else {
            throw WhoError.invalidModel("the \(variant.rawValue) precision is published for Apple platforms only; this platform runs int8")
        }
        var sessions: [String: any InferenceSession] = [:]
        for graph in ModelVariant.graphs {
            sessions[graph] = try await files.inferenceSession(
                model: variant.compiled(graph), computeUnits: computeUnits, sdk: WhoModel.sdkInfo)
        }
        let directory = variant.directory(for: .current)
        return ModelAssets(
            metaJSON: try files.readString("\(directory)/\(WhoModel.meta)"),
            melBanks: try files.read("\(directory)/\(WhoModel.melBanks)"),
            voiceBanks: try files.read("\(directory)/\(WhoModel.voiceBanks)"),
            embedding: try files.read("\(directory)/\(WhoModel.embedding)"),
            sessions: sessions)
    }
}
