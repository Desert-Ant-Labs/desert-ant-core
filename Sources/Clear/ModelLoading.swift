// How Clear obtains and shapes its model: the download/adopt sources and the
// `ModelAssets` the pipeline consumes. (Running the model is `Enhancer.swift`.)
// All platform variation is data (which artifact ships where, declared in
// `Catalog.swift`); building the platform's session is DesertAnt's
// `inferenceSession` factory - Core ML on Apple, LiteRT on Android/Linux, the JS
// host on the web.
import DesertAnt

// The SDK's usage identity (`ClearModel.sdkInfo`) is derived from the catalog
// declaration's `product` + `sdkVersion`, so it cannot drift from the published
// package version or be forgotten on a session.

/// Ready inference sessions for the enhancement model. A pool (one per worker)
/// lets the chunk loop use multiple cores on native platforms; usually one.
///
/// Also the entry point for the cross-language bindings and custom deployments
/// (not part of the Swift SDK's public API, which loads the model for you).
@_spi(ClearBindings)
public struct ModelAssets: Sendable {
    let sessions: [any InferenceSession]
    /// Which published variant these sessions run, reported on `Result`. Nil
    /// when the artifact is not a published variant (a custom export, or a
    /// wasm host that compiled the model itself).
    let variant: ModelVariant?
    /// The repo revision the sessions' artifact was resolved from, reported on
    /// `Result`. Nil for a local `modelPath`, explicit assets, or a wasm host
    /// (nothing was downloaded, so no revision applies).
    let revision: String?
    /// Which runtime opened the artifact, reported on `Result`. Nil when only
    /// the host knows (a wasm session).
    let runtime: ModelRuntime?

    init(sessions: [any InferenceSession], variant: ModelVariant? = nil,
         revision: String? = nil, runtime: ModelRuntime? = nil) {
        self.sessions = sessions
        self.variant = variant
        self.revision = revision
        self.runtime = runtime
    }

    /// Bindings entry point: build from an already-constructed session (e.g. the
    /// wasm host's `JSInferenceSession`), whose variant only the host knows.
    @_spi(ClearBindings)
    public init(session: any InferenceSession, variant: ModelVariant? = nil) {
        self.init(sessions: [session], variant: variant)
    }

    /// Sessions over an artifact already on disk. The variant is read off the
    /// file name, so a pre-downloaded artifact still identifies itself on
    /// `Result`.
    init(modelPath: String, revision: String? = nil,
         computeUnits: ComputeUnits = .all, concurrency: Int = 1) throws {
        self.init(
            sessions: try (0..<max(1, concurrency)).map { _ in
                try inferenceSession(modelPath: modelPath, computeUnits: computeUnits, sdk: ClearModel.sdkInfo)
            },
            variant: ModelVariant.inferred(fromPath: modelPath),
            revision: revision,
            runtime: ModelRuntime.inferred(fromPath: modelPath))
    }

    /// Build from a resolved model directory: one session per worker over this
    /// platform's artifact.
    /// Where this model runs, measured on this machine rather than left to
    /// `.all`. The GPU is a candidate because it is much faster - 338 RTFx
    /// against 514 over ten minutes on an M3 Ultra - and because what it
    /// produces is the same audio: against `.all` the difference is 47.6 dB
    /// below the signal on two full-length recordings, never louder than -62
    /// dBFS in any second, with no clipping and no level change.
    ///
    /// Not on a phone, where the GPU is an order of magnitude slower than the
    /// engine for this model (12.7 ms a dispatch against 143) and is also
    /// drawing the screen.
    /// The engine is a candidate too, though it measures worse on every machine
    /// so far (247 RTFx against 514 on an M3 Ultra). It is here because that is
    /// four machines, not a rule, and because its output is bit-identical to
    /// `.all` - so the only cost of being wrong about it is one slow launch.
    ///
    /// Only M-series silicon chooses - see `Placement.explores`. A phone pins
    /// the engine, which costs it nothing here (341 RTFx either way on an iPhone
    /// 16 Pro) and leaves the GPU to the screen.
    static var placements: [(name: String, units: ComputeUnits)] {
        guard Placement.explores else {
            // Apple silicon without an M in the name is a phone, and a phone
            // pins the engine. Anything else is an Intel or AMD Mac with no
            // engine to choose between, so Core ML's own default stands.
            #if os(macOS) || !canImport(CoreML) || targetEnvironment(simulator)
            return [("all", .all)]
            #else
            return [("ane", .cpuAndNeuralEngine)]
            #endif
        }
        return [("all", .all), ("gpu", .cpuAndGPU), ("ane", .cpuAndNeuralEngine)]
    }

    static func clear(files: StoredModel, variant: ModelVariant, revision: String? = nil,
                      runtime: ModelRuntime = .platformDefault,
                      computeUnits: ComputeUnits, concurrency: Int) async throws -> ModelAssets {
        let artifact = variant.artifact(for: runtime)
        // The caller's choice wins; `.all` is the default nobody asked for, so
        // that is the one a measurement is allowed to replace.
        let placement = computeUnits == .all && artifact.hasSuffix(".mlmodelc")
            ? Placement.next(model: files.path(artifact), candidates: placements)
            : (name: "caller", units: computeUnits)
        var sessions: [any InferenceSession] = []
        for _ in 0..<max(1, concurrency) {
            sessions.append(try await files.inferenceSession(
                model: artifact, computeUnits: placement.units, sdk: ClearModel.sdkInfo))
        }
        return ModelAssets(sessions: sessions, variant: variant, revision: revision,
                           runtime: runtime)
    }
}

public extension Clear {
    /// The published model repository.
    static var modelRepo: String { ClearModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { ClearModel.revision }
}

// MARK: shipping the model with your app

// This package bundles no model artifact and has no resource bundle to load one
// from. The model is downloaded on demand: to a managed cache location by
// default, or to the `directory` you pass. Shipping the model with your app is
// therefore just pointing `directory` at a folder that already holds this
// platform's artifact - it is then used offline, with no download. (Android's
// equivalent is classpath resources, and wasm always downloads.)
