import DesertAnt

/// Options controlling recognition.
public struct Options: Sendable, Equatable {
    /// The lowest model confidence Shapes accepts, on top of its own checks.
    /// The default `0` applies only its own checks.
    public var minimumConfidence: Double
    /// How Shapes snaps rotation. `.snapped`, the default, rounds rotations to
    /// 15° steps. `.upright` removes rotation, and `.free` keeps the shape as drawn.
    public var rotation: Rotation
    /// The kinds Shapes recognizes, all of them by default. For a stroke of any
    /// other kind, `recognize` returns `nil`. For example, leave out `.scribble`
    /// if your app has no erase gesture.
    public var kinds: Set<Shape.Kind>
    /// Whether the drawing is finished: the pen has lifted and your app is
    /// snapping it. A finished drawing snaps only once its outline is drawn, so
    /// a half-drawn rectangle comes back `nil`. Pass `false` for a preview
    /// while the pen is still moving: Shapes then returns the shape the drawing
    /// is becoming without waiting for its outline.
    public var isFinished: Bool

    public init(minimumConfidence: Double = 0, rotation: Rotation = .snapped,
                kinds: Set<Shape.Kind> = Set(Shape.Kind.allCases), isFinished: Bool = true) {
        self.minimumConfidence = minimumConfidence.isFinite ? min(1, max(0, minimumConfidence)) : 0
        self.rotation = rotation
        self.kinds = kinds
        self.isFinished = isFinished
    }
}

/// One stroke of ink as drawn: its points in canvas coordinates and, when you
/// have them, the time of each point.
public struct Stroke: Sendable, Equatable {
    /// The points in drawing order.
    public var points: [Point]
    /// The time of each point in milliseconds, on any clock that runs forward
    /// and that every stroke of the drawing shares, so the pauses between
    /// strokes show. Give times for every stroke or for none: without them,
    /// Shapes reads the strokes as drawn at a steady pace.
    public var times: [Double]

    public init(points: [Point], times: [Double] = []) {
        self.points = points
        self.times = times
    }
}

/// One recognition with what led to it (see ``Shapes/inspect(strokes:options:)``).
@_spi(ShapesDiagnostics)
public struct Inspection: Sendable {
    /// Why a drawing came back `nil`.
    public enum Rejection: String, Sendable {
        /// Too short or too few points: a tap.
        case tap
        /// A coordinate that is not finite or lies beyond
        /// `Model.largestCoordinate` from the origin: not ink from a canvas.
        case invalid
        /// The model read it as none of the kinds.
        case notAShape
        /// Below `Options.minimumConfidence`.
        case confidence
        /// The fit stayed further from the ink than the kind's gate.
        case gate
        /// Much of the fitted outline is far from any ink: the shape is not
        /// finished yet (a ⊓ is not yet a rectangle).
        case undrawn
        /// A kind left out of `Options.kinds`.
        case kinds
    }

    /// Every kind's probability, most likely first.
    public var kinds: [(name: String, probability: Double)] = []
    /// The shape `recognize` returns, `nil` when rejected.
    public var shape: Shape?
    public var rejection: Rejection?
    /// The fit's residual (mean distance from the ink to the outline, over the
    /// ink's larger side) and the kind's gate (`nil`: no gate).
    public var residual: Double?
    public var gate: Double?
    /// The share of the fitted outline far from any ink, and the most that
    /// may be (the meta's limit for the kind, 15% otherwise).
    public var undrawn: Double?
    public var maximumUndrawn: Double?
    public var modelMilliseconds: Double = 0
    public var fitMilliseconds: Double = 0

    init(kinds: [(name: String, probability: Double)] = [], rejection: Rejection? = nil, modelMilliseconds: Double = 0) {
        self.kinds = kinds
        self.rejection = rejection
        self.modelMilliseconds = modelMilliseconds
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

/// On-device shape recognition from a few strokes of ink.
///
/// `Shapes` turns a hand-drawn shape into a clean ``Shape`` on the device: a
/// line or curve, an arrow, a rectangle, an ellipse, a triangle, a diamond, a
/// pentagon, a hexagon, a star, a heart, a cloud, a scribble (your app can use
/// it as an erase gesture), a check, a cross, a plus, a bracket, or a zigzag.
/// The shape can take a few strokes, such as a cross or a box drawn side by
/// side. For any other ink, `recognize` returns `nil`, so you can keep it as
/// ink.
///
/// A small model reads the kind and the shape's numbers, and a fit moves the
/// clean shape onto the ink. Shapes accepts a drawing only if the fit clears
/// that kind's threshold. Create one `Shapes` and reuse it.
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

    /// Recognizes a drawing of one or more strokes in canvas coordinates.
    /// Returns the clean ``Shape``, or `nil` for ink that isn't a shape or isn't
    /// one of `options.kinds`.
    public func recognize(strokes: [Stroke], options: Options = .init()) async throws -> Shape? {
        try await model.value().recognize(strokes: strokes, options: options)
    }

    /// One recognition with what led to it, for test tools: every kind's
    /// probability, the fit's residual against the kind's gate, why a drawing
    /// came back `nil`, and the time the model and the fit took.
    @_spi(ShapesDiagnostics)
    public func inspect(strokes: [Stroke], options: Options = .init()) async throws -> Inspection {
        try await model.value().inspect(strokes: strokes, options: options)
    }

    /// Recognizes one stroke given as ordered ``Point`` values in canvas
    /// coordinates, read as drawn at a steady pace. Returns the clean ``Shape``,
    /// or `nil` for a stroke that isn't a shape or isn't one of `options.kinds`.
    public func recognize(points: [Point], options: Options = .init()) async throws -> Shape? {
        try await recognize(strokes: [Stroke(points: points)], options: options)
    }
}
