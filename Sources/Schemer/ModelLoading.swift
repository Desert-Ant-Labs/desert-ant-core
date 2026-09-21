// How Schemer obtains and shapes its model: the `ModelAssets` the pipeline
// consumes. (Running the model is `Model.swift`.) All platform variation is
// data here (which artifacts ship where, in `Catalog.swift`); building the
// platform's session is DesertAnt's `inferenceSession` factory.

import DesertAnt
import Foundation

/// Loaded model inputs: two sidecars plus four ways to make a session.
///
/// Four rather than one because sequence length is static on every backend
/// and the label candidate count varies per call. See `Catalog.swift`.
///
/// Also the entry point for the cross-language bindings and custom
/// deployments; the Swift SDK's public API loads assets for you.
@_spi(SchemerBindings)
public struct ModelAssets: Sendable {
    /// `schemer_tokenizer.bin`. Memory-mapped where there is a filesystem to
    /// map: it is ~11 MB and the tokenizer wants random access into it.
    public let tokenizer: Data
    /// `embeddings.q`, likewise mapped rather than read (79.6 MB).
    public let embeddings: Data
    /// Sessions are made on demand, not up front.
    ///
    /// Eagerly loading every window exhausts the Neural Engine's buffer pool
    /// ("Failed to allocate E5 buffer object"): the 1216 pair alone needs
    /// large IOSurfaces, and most records never reach it. Lazy loading keeps
    /// a short-record workload at three sessions instead of six.
    let makeEncoder: @Sendable (Int) async throws -> any InferenceSession
    let makeDecoder: @Sendable (Int) async throws -> any InferenceSession
    let makeQueryEncoder: @Sendable () async throws -> any InferenceSession
    let makeLabel: @Sendable () async throws -> any InferenceSession

    /// Bindings entry point: build from sidecar bytes and session factories
    /// (for example over the wasm host's `JSInferenceSession`).
    @_spi(SchemerBindings)
    public init(tokenizer: Data, embeddings: Data,
                makeEncoder: @escaping @Sendable (Int) async throws -> any InferenceSession,
                makeDecoder: @escaping @Sendable (Int) async throws -> any InferenceSession,
                makeQueryEncoder: @escaping @Sendable () async throws -> any InferenceSession,
                makeLabel: @escaping @Sendable () async throws -> any InferenceSession) {
        self.tokenizer = tokenizer
        self.embeddings = embeddings
        self.makeEncoder = makeEncoder
        self.makeDecoder = makeDecoder
        self.makeQueryEncoder = makeQueryEncoder
        self.makeLabel = makeLabel
    }

    /// Build from a resolved model directory: map the sidecars and let the
    /// core pick this platform's session for each artifact.
    ///
    /// The Neural Engine is requested explicitly. A fully ANE-compatible model
    /// can still be routed to CPU/GPU by Core ML's planner under `.all`, and
    /// residency is the whole point of how these graphs are authored. LiteRT
    /// ignores the hint and picks its own delegates.
    ///
    /// A window is a Core ML function or a LiteRT signature of one file, named
    /// the same on both (`encode_256`, `decode_1216`), so this is one code path.
    static func schemer(files: StoredModel) async throws -> ModelAssets {
        let sdk = SchemerModel.sdkInfo
        @Sendable func session(_ name: String, _ function: String?) async throws
            -> any InferenceSession {
            try await files.inferenceSession(model: name, computeUnits: .cpuAndNeuralEngine,
                                             functionName: function, sdk: sdk)
        }
        return ModelAssets(
            tokenizer: try sidecar(files, SchemerModel.tokenizer),
            embeddings: try sidecar(files, SchemerModel.embeddings),
            makeEncoder: { try await session(SchemerModel.encoder,
                                             Shapes.encodeFunction($0)) },
            makeDecoder: { try await session(SchemerModel.decode,
                                             Shapes.decodeFunction($0)) },
            makeQueryEncoder: { try await session(SchemerModel.encoder,
                                                  Shapes.encodeFunction(Shapes.query)) },
            makeLabel: { try await session(SchemerModel.label, nil) })
    }

    #if os(WASI)
    /// The browser's `modelBaseUrl` path: the page fetched every file and
    /// compiled the artifact (the encoder) itself, and everything else arrived
    /// as bytes keyed by catalog name. The encoder's windows are signatures of
    /// the page's model; decode and label are compiled on the host on first use.
    @_spi(SchemerBindings)
    public static func selfHosted(files: [String: [UInt8]]) throws -> ModelAssets {
        func need(_ name: String) throws -> [UInt8] {
            guard let bytes = files[name] else {
                throw SchemerError.invalidBundle("the model files are missing \(name)")
            }
            return bytes
        }
        let sdk = SchemerModel.sdkInfo
        let decode = try need(SchemerModel.liteRTDecode)
        let label = try need(SchemerModel.liteRTLabel)
        return ModelAssets(
            tokenizer: Data(try need(SchemerModel.tokenizer)),
            embeddings: Data(try need(SchemerModel.embeddings)),
            makeEncoder: { inferenceSession(hostModelSignature: Shapes.encodeFunction($0), sdk: sdk) },
            makeDecoder: {
                try await inferenceSession(hostModelBytes: decode, key: SchemerModel.liteRTDecode,
                                           signature: Shapes.decodeFunction($0), sdk: sdk)
            },
            makeQueryEncoder: {
                inferenceSession(hostModelSignature: Shapes.encodeFunction(Shapes.query), sdk: sdk)
            },
            makeLabel: {
                try await inferenceSession(hostModelBytes: label, key: SchemerModel.liteRTLabel,
                                           sdk: sdk)
            })
    }
    #endif

    /// A sidecar's bytes: mapped from disk, or read through the store's own
    /// filesystem on wasm, where the browser's is in memory and there is
    /// nothing to map.
    private static func sidecar(_ files: StoredModel, _ name: String) throws -> Data {
        #if os(WASI)
        Data(try files.read(name))
        #else
        try Data(contentsOf: URL(fileURLWithPath: files.path(name)), options: .mappedIfSafe)
        #endif
    }
}

public extension Schemer {
    /// The published model repository.
    static var modelRepo: String { SchemerModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { SchemerModel.revision }
}

// MARK: shipping the model with your app

// This package bundles no model artifact. The model is downloaded on demand:
// to a managed cache location by default, or to the `directory` you pass.
// Shipping the model with your app is therefore just pointing `directory` at
// a folder that already holds this platform's three artifacts plus the two
// sidecars - it is then used offline, with no download.
