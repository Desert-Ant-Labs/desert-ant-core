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
    /// Which runtime opened the detector, reported on `Result`. Nil when the
    /// session came from the bindings.
    let runtime: ModelRuntime?

    /// Bindings entry point: build from an already-constructed session (e.g.
    /// the wasm host's `JSInferenceSession`).
    @_spi(UhmBindings)
    public init(session: any InferenceSession) {
        self.session = session
        self.labelerModelPath = nil
        self.runtime = nil
    }

    init(session: any InferenceSession, labelerModelPath: String?, runtime: ModelRuntime?) {
        self.session = session
        self.labelerModelPath = labelerModelPath
        self.runtime = runtime
    }

    /// A session over an artifact already on disk (a `.mlmodelc` or `.aimodel` on Apple).
    init(modelPath: String, computeUnits: ComputeUnits = .cpuAndNeuralEngine) throws {
        self.init(session: try inferenceSession(
            modelPath: modelPath, computeUnits: computeUnits, sdk: UhmModel.sdkInfo),
            labelerModelPath: nil, runtime: ModelRuntime.inferred(fromPath: modelPath))
    }

    /// Build from a resolved model directory: a session over the selected tier's
    /// artifact for `runtime`, plus the type-labeler file when present.
    static func uhm(files: StoredModel, quality: Uhm.Quality, runtime: ModelRuntime = .platformDefault,
                    computeUnits: ComputeUnits) async throws -> ModelAssets {
        ModelAssets(
            session: try await files.inferenceSession(
                model: quality.artifact(for: runtime), computeUnits: computeUnits,
                sdk: UhmModel.sdkInfo),
            labelerModelPath: files.exists(UhmModel.labeler) ? files.path(UhmModel.labeler) : nil,
            runtime: runtime)
    }
}

public extension Uhm {
    /// The published model repository.
    static var modelRepo: String { UhmModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { UhmModel.revision }
}
