#if canImport(CoreGraphics)
import CoreGraphics


public extension Point {
    /// Create a point from a `CGPoint`.
    init(_ p: CGPoint) { self.init(x: Double(p.x), y: Double(p.y)) }
    /// The point as a `CGPoint`.
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

public extension Shape {
    /// The shape's outline as `CGPoint` values (see ``outline(samples:)``).
    func cgOutline(samples: Int = 64) -> [CGPoint] {
        outline(samples: samples).map(\.cgPoint)
    }

    /// A path to stroke or fill. The path closes every closed shape and draws
    /// curves and arrow shafts as cubic Beziers. For an arrow, the path adds each
    /// head as an open subpath with barbs `arrowheadLength` long.
    func path(arrowheadLength: CGFloat = 12) -> CGPath {
        let path = CGMutablePath()
        switch self {
        case let .curve(a, c1, c2, b), let .arrow(a, c1, c2, b, _, _):
            path.move(to: a.cgPoint)
            path.addCurve(to: b.cgPoint, control1: c1.cgPoint, control2: c2.cgPoint)
            for head in arrowheads(length: Double(arrowheadLength)) {
                path.addLines(between: head.map(\.cgPoint))
            }
        default:
            let pts = cgOutline()
            guard let first = pts.first else { return path }
            path.move(to: first)
            for p in pts.dropFirst() { path.addLine(to: p) }
            if isClosed { path.closeSubpath() }
        }
        return path
    }

    /// ``path(arrowheadLength:)`` with 12pt arrowhead barbs.
    var path: CGPath { path() }
}

public extension Shapes {
    /// Recognize a stroke given as ordered `CGPoint` values (canvas
    /// coordinates). Returns the clean ``Shape``, or `nil` for a stroke that
    /// isn't a shape.
    func recognize(points: [CGPoint], options: Options = .init()) async throws -> Shape? {
        try await recognize(points: points.map(Point.init), options: options)
    }
}
#endif
