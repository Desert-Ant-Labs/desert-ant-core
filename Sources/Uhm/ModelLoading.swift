// How Uhm obtains and shapes its model: the download/adopt sources and the
// `ModelAssets` the pipeline consumes. (Running the model is `Detector.swift`.)
// All platform variation is data (which artifact ships where, declared in
// `Catalog.swift`); building the platform's session is DesertAnt's
// `inferenceSession` factory - Core ML on Apple, LiteRT on Android/Linux, the
// JS host on the web.
import DesertAnt

// The SDK's usage identity (`UhmModel.sdkInfo`) is derived from the catalog
// declaration's `product` + `sdkVersion`, so it cannot drift from the published
// package version or be forgotten on a session.

/// A ready inference session for the frame-level detector.
///
/// Also the entry point for the cross-language bindings and custom deployments
/// (not part of the Swift SDK's public API, which loads the model for you).
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

    /// Where this model runs, measured on this machine rather than left to
    /// `.all`. The GPU is a candidate because the detector is much faster there
    /// - 626 RTFx against 1323 over ten minutes on an M3 Ultra, 297 against 367
    /// on an M5 - and because it detects the same fillers: the same count on
    /// four full-length recordings, with span boundaries within one 20 ms frame
    /// and confidences within 0.02.
    ///
    /// Apple platforms with a GPU worth trying, which is not a phone: there the
    /// GPU is 5 to 10 times slower than the engine for every model here and is
    /// also drawing the screen.
    /// The engine is a candidate too, though it has not won anywhere yet - 261
    /// RTFx against 1323 on an M3 Ultra, 300 against 367 on an M5. It is here
    /// because "has not won on the four machines someone owned" is the reasoning
    /// this exists to replace, and because a chip whose GPU is weak or whose
    /// engine is a generation ahead would want it. It costs one slow launch to
    /// find out, once per machine.
    ///
    /// Only M-series silicon chooses - see `Placement.explores`. A phone pins
    /// the engine, which measures faster there anyway (180 RTFx against 167 at
    /// `.all` on an iPhone 16 Pro) and leaves the GPU to the screen.
    static var placements: [(name: String, units: ComputeUnits)] {
        guard Placement.explores else {
            // Apple silicon without an M in the name is a phone, and a phone
            // pins the engine. Anything else is an Intel or AMD Mac with no
            // engine to choose between, so Core ML's own default stands.
            #if os(macOS)
            return [("all", .all)]
            #else
            return [("ane", .cpuAndNeuralEngine)]
            #endif
        }
        return [("all", .all), ("gpu", .cpuAndGPU), ("ane", .cpuAndNeuralEngine)]
    }

    /// A session over an artifact already on disk (a `.mlmodelc` on Apple).
    init(modelPath: String, computeUnits: ComputeUnits = .all) throws {
        self.init(session: try inferenceSession(
            modelPath: modelPath, computeUnits: computeUnits, sdk: UhmModel.sdkInfo),
            labelerModelPath: nil)
    }

    /// Build from a resolved model directory: this platform's session over the
    /// selected tier's artifact, plus the type-labeler file when present.
    static func uhm(files: StoredModel, quality: Uhm.Quality,
                    computeUnits: ComputeUnits) async throws -> ModelAssets {
        let artifact = quality.artifact(for: .current)
        // The caller's choice wins; `.all` is the default nobody asked for, so
        // that is the one the measurement is allowed to replace.
        let placement = computeUnits == .all
            ? Placement.next(model: files.path(artifact), candidates: placements)
            : (name: "caller", units: computeUnits)
        return ModelAssets(
            session: try await files.inferenceSession(
                model: artifact, computeUnits: placement.units, sdk: UhmModel.sdkInfo),
            labelerModelPath: files.exists(UhmModel.labeler) ? files.path(UhmModel.labeler) : nil)
    }
}

public extension Uhm {
    /// The published model repository.
    static var modelRepo: String { UhmModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { UhmModel.revision }
}

// MARK: shipping the model with your app

// This package bundles no artifacts and has no resource bundle to load one
// from. The detector model and the tiny type-labeler head (Apple-only) are
// downloaded on demand: to a managed cache location by default, or to the
// `directory` you pass. Shipping the model with your app is therefore just
// pointing `directory` at a folder that already holds this platform's
// artifacts - they are then used offline, with no download.
