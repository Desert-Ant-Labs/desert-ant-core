// How __PRODUCT__ obtains its model: the file manifest, the download/adopt/bundle
// sources, and the `ModelAssets` the pipeline consumes. All platform variation is
// data here (which artifact ships where); building the platform's session is
// desert-ant-core's `inferenceSession` factory.
import Inference
import ModelStore

/// The model's file names and per-platform artifacts, in one place.
enum __PRODUCT__Model {
    static let meta = "__MODEL___meta.json"
    static let tflite = "__MODEL__.tflite"      // LiteRT platforms (Linux/Android/Windows) + wasm
    static let coreML = "__MODEL__.mlmodelc"    // Apple

    static var artifact: String { ModelPlatform.current == .apple ? coreML : tflite }
}

/// Loaded model inputs: the sidecar metadata plus a ready inference session.
@_spi(__PRODUCT__Bindings)
public struct ModelAssets: Sendable {
    public let metaJSON: String
    let session: any InferenceSession

    /// Bindings entry point: in-memory model files (the Android AAR reads them
    /// from classpath resources). Bytes must be the LiteRT (`.tflite`) export.
    public init(metaJSON: String, modelBytes: [UInt8]) throws {
        self.init(metaJSON: metaJSON, session: try inferenceSession(modelBytes: modelBytes))
    }

    /// Bindings entry point: load the artifact from a file path (the Node native).
    public init(metaJSON: String, modelPath: String) throws {
        self.init(metaJSON: metaJSON, session: try inferenceSession(modelPath: modelPath))
    }

    @_spi(__PRODUCT__Bindings)
    public init(metaJSON: String, session: any InferenceSession) {
        self.metaJSON = metaJSON
        self.session = session
    }

    static func __MODEL__(files: StoredModel) async throws -> ModelAssets {
        ModelAssets(
            metaJSON: try files.readString(__PRODUCT__Model.meta),
            session: try await files.inferenceSession(model: __PRODUCT__Model.artifact, hostGlobal: "__HOSTGLOBAL__"))
    }
}

public extension __PRODUCT__ {
    /// The published model repository.
    static var modelRepo: String { "desert-ant-labs/__MODEL__" }
    /// The model revision this SDK is built against (pinned; not configurable).
    static var modelRevision: String { "v0.1.0" }

    internal static func resolvedAssets(
        directory: String?,
        cacheRoot: String? = nil,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws -> ModelAssets {
        let files = try await distribution().resolve(cacheDirectory: directory, cacheRoot: cacheRoot) { progress($0.fraction) }
        return try await .__MODEL__(files: files)
    }

    internal static func isModelAvailable(directory: String?, cacheRoot: String? = nil) -> Bool {
        distribution().isAvailable(cacheDirectory: directory, cacheRoot: cacheRoot)
    }

    private static func distribution() -> ModelDistribution {
        let tflite = [__PRODUCT__Model.tflite, __PRODUCT__Model.meta]
        return ModelDistribution(
            repo: modelRepo,
            revision: modelRevision,
            files: [
                .apple: [__PRODUCT__Model.coreML + "/", __PRODUCT__Model.meta],
                .android: tflite,
                .linux: tflite,
                .windows: tflite,
                .web: tflite,
            ]
        )
    }
}
