// How Emo obtains and shapes its model: the file manifest, the
// download/adopt/bundle sources, and the `ModelAssets` the pipeline consumes.
// (Running the model is `Model.swift`.) All platform variation is data here
// (which artifact ships where); building the platform's session is
// DesertAnt's `inferenceSession` factory.
import DesertAnt

// The SDK's usage identity (`EmoModel.sdkInfo`) is derived from the catalog
// declaration's `product` + `sdkVersion`, so it cannot drift from the published
// package version or be forgotten on a session.

// The model's file names, per-platform manifest, repo and pinned revision live
// in the monorepo catalog (`ModelCatalog/Emo/Emo.swift`) as `EmoModel`, so
// tooling and this SDK read one declaration.

/// Loaded model inputs: the sidecar metadata, the semantic tokenizer bytes, and
/// a ready inference session. Also the entry point for the cross-language
/// bindings and custom deployments (not part of the Swift SDK's public API,
/// which loads assets for you).
@_spi(EmoBindings)
public struct ModelAssets: Sendable {
    /// Contents of `emo_meta.json` (labels + featurizer/tokenizer constants).
    public let metaJSON: String
    /// Contents of `emo_tokenizer.bin` (the pruned-unigram semantic tokenizer).
    public let tokenizer: [UInt8]
    /// The platform's ready-to-run session for the model artifact.
    let session: any InferenceSession

    /// Bindings entry point: in-memory model files (e.g. the Android AAR reads
    /// them from classpath resources). The model bytes must be the LiteRT
    /// (`.tflite`) export.
    public init(metaJSON: String, tokenizerBytes: [UInt8], modelBytes: [UInt8]) throws {
        self.init(
            metaJSON: metaJSON,
            tokenizer: tokenizerBytes,
            session: try inferenceSession(modelBytes: modelBytes, sdk: EmoModel.sdkInfo))
    }

    /// Bindings entry point: load the artifact from a file path (the Node
    /// server-side native's bundled path). `inferenceSession(modelPath:)`
    /// selects Core ML on Apple hosts (from the `.mlmodelc` directory) and
    /// LiteRT on Linux (from the `.tflite`), so this one call covers both - the
    /// unified Node bundling primitive. It is also mmap-based, sidestepping the
    /// from-bytes buffer-ownership pitfall.
    public init(metaJSON: String, tokenizerBytes: [UInt8], modelPath: String) throws {
        self.init(
            metaJSON: metaJSON,
            tokenizer: tokenizerBytes,
            session: try inferenceSession(modelPath: modelPath, sdk: EmoModel.sdkInfo))
    }

    /// Bindings entry point: build from an already-constructed session (e.g. the
    /// wasm host's `JSInferenceSession`) plus the sidecars.
    @_spi(EmoBindings)
    public init(metaJSON: String, tokenizer: [UInt8], session: any InferenceSession) {
        self.metaJSON = metaJSON
        self.tokenizer = tokenizer
        self.session = session
    }

    /// Build from a resolved model directory: read the sidecars and let the core
    /// pick this platform's session for the artifact.
    static func emo(files: StoredModel) async throws -> ModelAssets {
        ModelAssets(
            metaJSON: try files.readString(EmoModel.meta),
            tokenizer: try files.read(EmoModel.tokenizer),
            session: try await files.inferenceSession(model: EmoModel.artifact, hostGlobal: "__EmoHost", sdk: EmoModel.sdkInfo))
    }
}

public extension Emo {
    /// The published model repository.
    static var modelRepo: String { EmoModel.repo }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { EmoModel.revision }

    /// Resolve the model for `directory` (adopt your files, or download there),
    /// then build loadable assets. `nil` uses the managed cache.
    internal static func resolvedAssets(
        directory: String?,
        cacheRoot: String? = nil,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> ModelAssets {
        let files = try await distribution().resolve(cacheDirectory: directory, cacheRoot: cacheRoot) { progress($0.fraction) }
        return try await .emo(files: files)
    }

    /// Whether the model is available offline for `directory`.
    internal static func isModelAvailable(directory: String?, cacheRoot: String? = nil) -> Bool {
        distribution().isAvailable(cacheDirectory: directory, cacheRoot: cacheRoot)
    }

    private static func distribution() -> ModelDistribution { EmoModel.distribution }
}

// MARK: opt-in app bundling (Apple / Linux)

// This package ships no model artifact, so bundling means model files the app
// supplies: put this platform's artifact plus the sidecars in a resource bundle
// of your own and pass it. (Android's equivalent is classpath resources, and wasm
// always downloads.) This is the one platform conditional in the model code:
// `Bundle` is a Foundation type, so the initializer only exists where SwiftPM
// resource bundles do.
#if canImport(CoreML) || os(Linux)
import Foundation

public extension Emo {
    /// Load a model bundled into your app:
    ///
    /// ```swift
    /// let emo = Emo(bundle: myModelBundle)
    /// ```
    convenience init(bundle: Bundle) {
        self.init(
            resolve: { _ in try ModelAssets.emo(bundle: bundle) },
            isAvailable: { true }
        )
    }
}

extension ModelAssets {
    /// Build from a resource bundle: the sidecars plus this platform's session
    /// for the bundled artifact.
    static func emo(bundle: Bundle) throws -> ModelAssets {
        let resources = BundledResources(bundle)
        do {
            return ModelAssets(
                metaJSON: try resources.readString(EmoModel.meta),
                tokenizer: try resources.read(EmoModel.tokenizer),
                session: try inferenceSession(modelPath: try resources.path(EmoModel.artifact), sdk: EmoModel.sdkInfo))
        } catch {
            throw EmoError.modelNotFound
        }
    }
}
#endif
