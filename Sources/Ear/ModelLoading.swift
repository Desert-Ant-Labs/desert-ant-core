// How Ear obtains and shapes its model: the sidecars it reads and the session it
// runs. (Running the model is `Model.swift`.) All platform variation is data
// here (which artifact ships where); building the platform's session is
// DesertAnt's `inferenceSession` factory.
import DesertAnt

/// Loaded model inputs: the sidecar files and a ready inference session. Also
/// the entry point for the cross-language bindings and custom deployments (not
/// part of the Swift SDK's public API, which loads assets for you).
@_spi(EarBindings)
public struct ModelAssets: Sendable {
    /// Contents of `languages.json`: the codes the head emits, in head order.
    public let languagesJSON: String
    /// Contents of `ear_meta.json`: frontend geometry and artifact description.
    public let metaJSON: String
    /// Contents of `mel_filters.f32`: `[mels, bins]` header then the table.
    public let melFilters: [UInt8]
    /// The platform's ready-to-run session for the model artifact.
    let session: any InferenceSession

    /// Bindings entry point: build from an already-constructed session (e.g. the
    /// wasm host's `JSInferenceSession`) plus the sidecars.
    @_spi(EarBindings)
    public init(languagesJSON: String, metaJSON: String, melFilters: [UInt8],
                session: any InferenceSession) {
        self.languagesJSON = languagesJSON
        self.metaJSON = metaJSON
        self.melFilters = melFilters
        self.session = session
    }

    /// Build from a resolved model directory: read the sidecars and let the core
    /// pick this platform's session for the artifact.
    static func ear(files: StoredModel) async throws -> ModelAssets {
        ModelAssets(
            languagesJSON: try files.readString(EarModel.languages),
            metaJSON: try files.readString(EarModel.meta),
            melFilters: try files.read(EarModel.melFilters),
            session: try await files.inferenceSession(
                model: EarModel.artifact(for: .current), sdk: EarModel.sdkInfo))
    }
}
