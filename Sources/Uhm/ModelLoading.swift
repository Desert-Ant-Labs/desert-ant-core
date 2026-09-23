import DesertAnt

/// A ready inference session for the frame-level detector. The entry point for
/// custom deployments; the public Swift API loads the model itself.
@_spi(UhmBindings)
public struct ModelAssets: Sendable {
    let session: any InferenceSession
    /// Path of the downloaded type-labeler model (Apple-only; `nil` when the
    /// assets were built without a resolved model directory, e.g. from the
    /// bindings, or when the file is absent).
    let labelerModelPath: String?

    /// Bindings entry point: build from an already-constructed session (e.g.
    /// the wasm host's `JSInferenceSession`).
    @_spi(UhmBindings)
    public init(session: any InferenceSession) {
        self.session = session
        self.labelerModelPath = nil
    }

    init(session: any InferenceSession, labelerModelPath: String?) {
        self.session = session
        self.labelerModelPath = labelerModelPath
    }

    /// A session over an artifact already on disk (a `.mlmodelc` on Apple).
    init(modelPath: String, computeUnits: ComputeUnits = .cpuAndNeuralEngine) throws {
        self.init(session: try inferenceSession(
            modelPath: modelPath, computeUnits: computeUnits, sdk: UhmModel.sdkInfo),
            labelerModelPath: nil)
    }

    /// Build from a resolved model directory: this platform's session over the
    /// selected tier's artifact, plus the type-labeler file when present.
    static func uhm(files: StoredModel, quality: Uhm.Quality,
                    computeUnits: ComputeUnits) async throws -> ModelAssets {
        ModelAssets(
            session: try await files.inferenceSession(
                model: quality.artifact(for: .current), computeUnits: computeUnits,
                sdk: UhmModel.sdkInfo),
            labelerModelPath: files.exists(UhmModel.labeler) ? files.path(UhmModel.labeler) : nil)
    }
}

public extension Uhm {
    /// The published model repository.
    static var modelRepo: String { UhmModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { UhmModel.revision }
}
