import DesertAnt

/// Options controlling recognition.
public struct Options: Sendable {
    /// Minimum classifier confidence, on top of each class's calibrated gate.
    /// `0` (the default) applies only the model's own gates.
    public var minimumConfidence: Double
    /// Geometry regularization ("smart shape" snapping) applied to the fitted
    /// output. Defaults to the standard snaps (axis-aligned lines, circles,
    /// squares, equilateral/isosceles triangles).
    var snap: SnapConfig

    public init(minimumConfidence: Double = 0) {
        self.minimumConfidence = minimumConfidence.isFinite
            ? min(1, max(0, minimumConfidence))
            : 0
        self.snap = .standard
    }
}

/// Errors thrown while loading or running the model. (`MessageError` is
/// `LocalizedError` wherever Foundation exists, so `localizedDescription`
/// shows `message`.)
public enum ShapesError: MessageError, Sendable {
    /// A model resource (model or metadata) could not be found.
    case resourceMissing
    /// On-device prediction failed or returned an unexpected output.
    case predictionFailed

    public var message: String {
        switch self {
        case .resourceMissing: "A Shapes model resource was not found."
        case .predictionFailed: "On-device shape recognition failed."
        }
    }
}

/// On-device single-stroke shape recognition.
///
/// `Shapes` turns one hand-drawn stroke into a clean vector ``Shape`` (line,
/// rectangle, triangle, ellipse, or star), fully on device. A small classifier
/// proposes a shape through the shared inference session (Core ML on Apple,
/// LiteRT elsewhere); a geometric fitter produces the clean parameters and a fit
/// residual; the stroke is accepted only if it clears that class's calibrated
/// confidence and residual gates. Create one once and reuse it.
///
/// ```swift
/// let shapes = Shapes()
/// if let shape = try await shapes.recognize(points: strokePoints) {
///     // shape == .rectangle(corners: [...]) etc.
/// }
/// ```
public final class Shapes: @unchecked Sendable {
    // Resolving the files, loading once, sharing that load, and reporting
    // availability are the same for every model, so they live in the core's
    // `LoadedModel`; Shapes adds only how a resolved directory becomes its model.
    private let model: LoadedModel<Model>

    /// Creates a recognizer. Construction does no work and starts no download;
    /// the model loads on the first ``recognize(points:options:)`` or
    /// ``download(progress:)``, off your calling thread.
    ///
    /// `directory` is where the model lives. If it already contains the model
    /// (you pre-downloaded or shipped it there) it is used offline; otherwise
    /// the model is downloaded into it and reused offline afterward. With no
    /// `directory` (the default), a managed cache location is used.
    ///
    /// Nothing is bundled with this package. To ship the model with your app,
    /// point `directory` at a folder you populated with the model files: it is
    /// used as-is, offline, and nothing is downloaded.
    public convenience init(directory: String? = nil) {
        self.init(directory: directory, cacheRoot: nil)
    }

    /// Binding entry point that also supplies the platform base cache root under
    /// which the managed layout lives (the app cache dir on Android, node
    /// `~/.cache` on the web). On Apple/Linux FileManager provides it, so the
    /// public `init(directory:)` passes `nil`.
    @_spi(ShapesBindings)
    public init(directory: String?, cacheRoot: String?) {
        model = LoadedModel(ShapesModel.self, directory: directory, cacheRoot: cacheRoot) { files in
            try Model(assets: await .shapes(files: files))
        }
    }

    /// Creates a recognizer from explicitly provided assets (used by the
    /// wasm self-hosted and custom-deployment paths).
    @_spi(ShapesBindings)
    public init(assets: ModelAssets) {
        model = LoadedModel { try Model(assets: assets) }
    }

    /// Whether the model is available for this recognizer with no network:
    /// cached (for the managed location) or already present in `directory`.
    public func isDownloaded() -> Bool { model.isDownloaded() }

    /// Download and load the model ahead of time, so the first
    /// ``recognize(points:options:)`` is instant. Reports download progress
    /// `0...1`. Concurrent calls, and an implicit load from a recognition, share
    /// one download. A no-op once loaded (see ``isDownloaded()``).
    public func download(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        try await model.download(progress: progress)
    }

    /// Await model readiness. The bindings use this to surface load errors
    /// eagerly; apps can just call ``recognize(points:options:)``.
    @_spi(ShapesBindings)
    public func waitUntilLoaded() async throws {
        _ = try await model.value()
    }

    /// Recognize a stroke given as ordered ``Point`` values (canvas
    /// coordinates). Returns the snapped ``Shape``, or `nil` when the stroke is
    /// rejected or degenerate.
    public func recognize(points: [Point], options: Options = .init()) async throws -> Shape? {
        try await model.value().recognize(points: points, options: options)
    }
}
