import DesertAnt
import JSON

/// The parsed sidecars and one ready session per cascade stage. The entry point
/// for custom deployments; the public Swift API loads assets itself.
@_spi(AlignBindings)
public struct ModelAssets: Sendable {
    let config: RefinerConfig
    let melFilters: [Float]
    let calibrator: CorrectionCalibrator
    let coarse: any InferenceSession
    let fine: any InferenceSession
    let revision: String?

    /// Bindings entry point: build from already-constructed sessions plus the
    /// sidecars, still parsed here so every host gets the same validation.
    @_spi(AlignBindings)
    public init(configJSON: String, melFilters: [UInt8], calibratorBytes: [UInt8],
                coarse: any InferenceSession, fine: any InferenceSession, revision: String? = nil) throws {
        self.config = try JSONDecoder().decode(RefinerConfig.self, from: configJSON)
        guard melFilters.count % 4 == 0 else { throw CorrectionCalibrator.CalibratorError.invalidFormat }
        var mel = [Float](repeating: 0, count: melFilters.count / 4)
        for i in 0..<mel.count {
            let b = i * 4
            let bits = UInt32(melFilters[b]) | UInt32(melFilters[b + 1]) << 8
                | UInt32(melFilters[b + 2]) << 16 | UInt32(melFilters[b + 3]) << 24
            mel[i] = Float(bitPattern: bits)
        }
        self.melFilters = mel
        guard mel.count == config.n_mels * (config.n_fft / 2 + 1) else { throw CorrectionCalibrator.CalibratorError.invalidFormat }
        self.calibrator = try CorrectionCalibrator(bytes: calibratorBytes)
        self.coarse = coarse
        self.fine = fine
        self.revision = revision
    }

    /// Build from a resolved model directory: read the sidecars and let the core
    /// pick this platform's session for each stage.
    static func align(files: StoredModel, computeUnits: ComputeUnits, revision: String?) async throws -> ModelAssets {
        let platform = ModelPlatform.current
        return try ModelAssets(
            configJSON: try files.readString(AlignModel.config),
            melFilters: try files.read(AlignModel.melFilters),
            calibratorBytes: try files.read(AlignModel.calibratorFile),
            coarse: try await files.inferenceSession(model: AlignModel.coarseArtifact(for: platform),
                                                     computeUnits: computeUnits, sdk: AlignModel.sdkInfo),
            fine: try await files.inferenceSession(model: AlignModel.fineArtifact(for: platform),
                                                   computeUnits: computeUnits, sdk: AlignModel.sdkInfo),
            revision: revision)
    }
}

public extension Align {
    /// The published model repository.
    static var modelRepo: String { AlignModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { AlignModel.revision }
}
