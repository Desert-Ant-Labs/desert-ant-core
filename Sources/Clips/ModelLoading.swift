// How Clips obtains and shapes its models: the file manifest, the
// download/adopt sources, and the `ModelAssets` the pipeline consumes.
// (Running them is `Model.swift`.) All platform variation is data here (which
// exports ship where, declared in `Catalog.swift`); building the platform's
// session is DesertAnt's `inferenceSession` factory.
import DesertAnt

// The SDK's usage identity (`ClipModel.sdkInfo`) is derived from the catalog
// declaration's `product` + `sdkVersion`, so it cannot drift from the published
// package version or be forgotten on a session.

/// Loaded model inputs: the tokenizer vocab and one ready session per export.
/// Also the entry point for the cross-language bindings and custom deployments
/// (not part of the Swift SDK's public API, which loads assets for you).
///
/// Two sessions, not one: selection is a per-sentence pass through the selector
/// and then a per-span pass through the scorer, and they are separate graphs
/// with different inputs. On Apple those two graphs live in one multifunction
/// asset, so the sessions share a file and are told apart by function name.
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
    static func clip(files: StoredModel) async throws -> ModelAssets {
        ModelAssets(
            tokenizer: try files.read(ClipModel.tokenizer),
            selector: try await files.session(ClipModel.selector),
            scorer: try await files.session(ClipModel.scorer))
    }
}

extension StoredModel {
    /// Open one half of the pipeline: the file, and the function inside it when
    /// the artifact carries more than one.
    ///
    /// The function name is the easy part to drop, and Core ML raises nothing
    /// when it is missing: it loads the package's default function, so both
    /// halves of the pipeline become the selector. Here that surfaces later as
    /// a prediction failure about a missing `score`, which points at the model
    /// rather than at the load that never addressed a graph. On Apple the two
    /// halves are one asset (``ClipModel/coreML``); everywhere else the name is
    /// `nil` and this is an ordinary per-file load.
    func session(_ export: ClipModel.Export) async throws -> any InferenceSession {
        try await inferenceSession(model: export.file, functionName: export.function,
                                   sdk: ClipModel.sdkInfo)
    }
}

public extension Clips {
    /// The published model repository.
    static var modelRepo: String { ClipModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { ClipModel.revision }
}

// MARK: shipping the model with your app

// This package bundles no model artifact and has no resource bundle to load
// one from. The model is downloaded on demand: to a managed cache location by
// default, or to the `directory` you pass. Shipping the model with your app is
// therefore just pointing `directory` at a folder that already holds this
// platform's exports plus the tokenizer - it is then used offline, with no
// download. (Android's equivalent is classpath resources.)
