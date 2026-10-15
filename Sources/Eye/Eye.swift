import DesertAnt

/// On-device photo understanding: find and filter the photos you want.
///
/// One call tags a photo: what it is (`.screenshot`, `.receipt`, `.selfie`),
/// what is in it (`.dog`, `.beach`), how it came out (`.blurry`,
/// `.eyesClosed`), who is in it (`.groupShot`, `.portrait`) and whether it is
/// sensitive. Every tag has a confidence where 0.5 is the recommended cutoff
/// and 0.9 a strict one. Runs on Core ML on Apple platforms and LiteRT
/// everywhere else. Create one and reuse it.
///
/// ```swift
/// let eye = Eye()
/// let photo = try await eye.analyze(contentsOf: url)
/// if photo.has(.dog) && !photo.has(.blurry) { keep(photo) }
/// let groups = Eye.duplicates(in: library)
/// ```
public final class Eye: @unchecked Sendable {
    private let model: LoadedModel<Model>

    /// Creates an eye. Construction does no work; the model loads on the first
    /// ``analyze(_:options:)`` or ``download(progress:)``.
    ///
    /// `directory` is where the model lives. If it already holds the model it is
    /// used offline; otherwise the model is downloaded into it. With no
    /// `directory`, a managed cache location is used.
    public convenience init(directory: String? = nil) {
        self.init(directory: directory, cacheRoot: nil)
    }

    /// Binding entry point that also supplies the platform base cache root.
    @_spi(EyeBindings)
    public init(directory: String?, cacheRoot: String?) {
        model = LoadedModel(EyeModel.self, directory: directory, cacheRoot: cacheRoot) { files in
            Model(assets: try await .eye(files: files))
        }
    }

    /// Creates an eye from explicitly provided assets (the wasm self-hosted and
    /// custom-deployment paths).
    @_spi(EyeBindings)
    public init(assets: ModelAssets) {
        model = LoadedModel { Model(assets: assets) }
    }

    /// Whether the model is available with no network.
    public func isDownloaded() -> Bool { model.isDownloaded() }

    /// Download and load the model ahead of time, reporting progress `0...1`.
    /// A no-op once loaded.
    public func download(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        try await model.download(progress: progress)
    }

    /// Await model readiness, so the bindings can surface load errors eagerly.
    @_spi(EyeBindings)
    public func waitUntilLoaded() async throws {
        _ = try await model.value()
    }

    /// Analyze an image (upright, any size). Throws `CancellationError` promptly
    /// if the calling task is cancelled.
    public func analyze(_ image: ImagePixels, options: Options = .init()) async throws -> Analysis {
        try Task.checkCancellation()
        let model = try await model.value()
        try Task.checkCancellation()
        // One image is one billed call, however many functions and faces it runs.
        return try await InferenceContext.withCallGroup {
            try await model.analyze(image, options: options)
        }
    }
}
