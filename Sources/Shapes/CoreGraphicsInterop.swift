#if canImport(CoreGraphics)
import CoreGraphics

// Apple-only ergonomics: convert between the portable `Point` and `CGPoint`,
// render a fitted `Shape` to a `CGPath`, and accept `CGPoint` strokes directly.
// CoreGraphics exists only on Apple platforms, so this whole file is gated and
// never affects the Android/wasm builds.

public extension Point {
    /// Create a point from a `CGPoint`.
    init(_ p: CGPoint) { self.init(x: Double(p.x), y: Double(p.y)) }
    /// The point as a `CGPoint`.
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

public extension Shape {
    /// The shape's outline as `CGPoint` values (see ``outline(samples:)``).
    func cgOutline(samples: Int = 96) -> [CGPoint] {
        outline(samples: samples).map(\.cgPoint)
    }

    /// A renderable path. Closed for all shapes except `.line`.
    var path: CGPath {
        let pts = cgOutline()
        let path = CGMutablePath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        if case .line = self {} else { path.closeSubpath() }
        return path
    }
}

public extension Shapes {
    /// Recognize a stroke given as ordered `CGPoint` values (canvas
    /// coordinates). Returns the snapped ``Shape``, or `nil` when rejected or
    /// degenerate.
    func recognize(points: [CGPoint], options: Options = .init()) async throws -> Shape? {
        try await recognize(points: points.map(Point.init), options: options)
    }
}
#endif
