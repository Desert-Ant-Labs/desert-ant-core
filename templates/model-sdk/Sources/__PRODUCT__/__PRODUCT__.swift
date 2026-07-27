import Inference
import ModelStore
import PlatformSupport

/// The result __PRODUCT__ produces. Replace with this model's real output.
public struct __PRODUCT__Result: Sendable, Equatable {
    public let label: String
    public let confidence: Double
    public init(label: String, confidence: Double) {
        self.label = label
        self.confidence = confidence
    }
}

public enum __PRODUCT__Error: Error, Sendable {
    case resourceMissing
    case notReady
}

/// On-device __DESCRIPTION_SHORT__.
///
/// ```swift
/// let __MODEL__ = __PRODUCT__()
/// let result = try await __MODEL__.run("input")
/// ```
///
/// This is a working skeleton: it loads the model through desert-ant-core's
/// ModelStore + inference session factory exactly as the real SDK will, and
/// returns a stub result. Replace `run` (and `__PRODUCT__Result`) with the real
/// pipeline; the loading, platform, FFI, and packaging layers need no changes.
public final class __PRODUCT__: @unchecked Sendable {
    private let loader: LazyLoader<ModelAssets>

    /// Load the model on demand, caching it under the managed cache location.
    /// `directory` adopts an already-populated folder instead of downloading.
    public convenience init(directory: String? = nil) {
        self.init(directory: directory, cacheRoot: nil)
    }

    /// Bindings entry point (Android/Node pass an explicit cache root).
    public convenience init(directory: String?, cacheRoot: String?) {
        self.init(resolve: { progress in
            try await __PRODUCT__.resolvedAssets(directory: directory, cacheRoot: cacheRoot, progress: progress)
        })
    }

    /// Bindings entry point: already-built assets (the wasm host, bundled apps).
    public convenience init(assets: ModelAssets) {
        self.init(resolve: { _ in assets })
    }

    init(resolve: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> ModelAssets) {
        self.loader = LazyLoader { progress in try await resolve(progress) }
    }

    /// Whether the model is present locally (no network).
    public static func isAvailable(directory: String? = nil, cacheRoot: String? = nil) -> Bool {
        isModelAvailable(directory: directory, cacheRoot: cacheRoot)
    }

    /// Download the model if needed, reporting progress 0...1.
    public func download(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await loader.run(progress)
    }

    /// Run the model over `input`.
    ///
    /// TODO: replace the stub below with the real pipeline - preprocess `input`
    /// into tensors, call `assets.session.run(...)`, and decode the output.
    public func run(_ input: String, minimumConfidence: Double = 0) async throws -> __PRODUCT__Result? {
        let assets = try await loader.value()
        _ = assets
        guard !input.isEmpty else { return nil }
        let result = __PRODUCT__Result(label: "stub", confidence: 1.0)
        return result.confidence >= minimumConfidence ? result : nil
    }
}
