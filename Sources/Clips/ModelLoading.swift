import DesertAnt

/// The tokenizer vocab and one ready session per export. The entry point for
/// custom deployments; the public Swift API loads assets itself.
///
/// On Apple both graphs live in one multifunction asset, so the two sessions
/// share a file and are told apart by function name.
@_spi(ClipBindings)
public struct ModelAssets: Sendable {
    /// Contents of `clip_tokenizer.bin` (the XLM-R unigram vocab).
    public let tokenizer: [UInt8]
    /// Per-sentence saliency + start/end probabilities.
    let selector: any InferenceSession
    /// Per-span quality score.
    let scorer: any InferenceSession

    /// Bindings entry point: build from already-constructed sessions plus the
    /// sidecar.
    @_spi(ClipBindings)
    public init(tokenizer: [UInt8], selector: any InferenceSession, scorer: any InferenceSession) {
        self.tokenizer = tokenizer
        self.selector = selector
        self.scorer = scorer
    }

    /// Build from a resolved model directory: read the sidecar and let the core
    /// pick this platform's session for each export.
    static func clip(files: StoredModel, computeUnits: ComputeUnits) async throws -> ModelAssets {
        ModelAssets(
            tokenizer: try files.read(ClipModel.tokenizer),
            selector: try await files.session(ClipModel.selector, computeUnits: computeUnits),
            scorer: try await files.session(ClipModel.scorer, computeUnits: computeUnits))
    }
}

extension StoredModel {
    /// Open one half of the pipeline: the file, and the function inside it when
    /// the artifact carries more than one.
    ///
    /// Core ML raises nothing when the function name is missing: it loads the
    /// default function, so both halves become the selector, surfacing later as
    /// a prediction failure about a missing `score`. Off Apple the name is `nil`
    /// and this is an ordinary per-file load.
    func session(_ export: ClipModel.Export,
                 computeUnits: ComputeUnits) async throws -> any InferenceSession {
        try await inferenceSession(model: export.file, computeUnits: computeUnits,
                                   functionName: export.function, sdk: ClipModel.sdkInfo)
    }
}

public extension Clips {
    /// The published model repository.
    static var modelRepo: String { ClipModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { ClipModel.revision }
}
