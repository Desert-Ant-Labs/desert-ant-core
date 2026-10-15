import DesertAnt

/// Options controlling recognition.
public struct Options: Sendable, Equatable {
    /// The lowest classifier confidence Shapes accepts, on top of each kind's
    /// calibrated threshold. The default `0` applies only the calibrated thresholds.
    public var minimumConfidence: Double
    /// How Shapes snaps rotation. `.snapped`, the default, rounds rotations to
    /// 15° steps. `.upright` removes rotation, and `.free` keeps the shape as drawn.
    public var rotation: Rotation
    /// The kinds Shapes recognizes, all of them by default. For a stroke of any
    /// other kind, `recognize` returns `nil`. For example, leave out `.scribble`
    /// if your app has no erase gesture.
    public var kinds: Set<Shape.Kind>

    public init(minimumConfidence: Double = 0, rotation: Rotation = .snapped,
                kinds: Set<Shape.Kind> = Set(Shape.Kind.allCases)) {
        self.minimumConfidence = minimumConfidence.isFinite ? min(1, max(0, minimumConfidence)) : 0
        self.rotation = rotation
        self.kinds = kinds
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
/// `Shapes` turns a hand-drawn stroke into a clean ``Shape`` on the device: a
/// line or curve, an arrow, a rectangle, an ellipse, a triangle, a diamond, a
/// pentagon, a hexagon, a star, a heart, a cloud, or a scribble, which your app
/// can use as an erase gesture. For any other stroke, such as handwriting,
/// `recognize` returns `nil`, so you can keep that stroke as ink.
///
/// A small model scores each kind, and a geometric fitter computes the clean
/// shape. Shapes accepts a stroke only if the model's confidence and the fit
/// both clear that kind's calibrated thresholds. Create one `Shapes` and reuse it.
///
/// ```swift
/// let shapes = Shapes()
/// switch try await shapes.recognize(points: strokePoints) {
/// case let .rectangle(corners)?: draw(corners)
/// case let .scribble(hull)?: erase(under: hull)
/// case nil: keepInk()
/// default: break
/// }
/// ```
public final class Shapes: @unchecked Sendable {
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

    /// The loaded model, for tests that read its raw outputs.
    func loadedModel() async throws -> Model { try await model.value() }

    /// Recognizes a stroke given as ordered ``Point`` values in canvas
    /// coordinates. Returns the clean ``Shape``, or `nil` for a stroke that
    /// isn't a shape or isn't one of `options.kinds`.
    public func recognize(points: [Point], options: Options = .init()) async throws -> Shape? {
        try await model.value().recognize(points: points, options: options)
    }
}
