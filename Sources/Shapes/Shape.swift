import RealModule

/// A recognized, fitted shape in the same coordinate space as the input stroke.
///
/// Point coordinates are ``Point`` values. On Apple platforms `CoreGraphics`
/// conveniences (`CGPoint`/`CGPath`) are provided for rendering.
public enum Shape: Sendable, Equatable {
    /// A straight line segment from `from` to `to`.
    case line(from: Point, to: Point)
    /// A rectangle given by its four corners, in order around the perimeter.
    case rectangle(corners: [Point])
    /// A triangle given by its three vertices.
    case triangle(vertices: [Point])
    /// An ellipse with the given center, semi-axes, and `rotation` (radians).
    case ellipse(center: Point, semiMajor: Double, semiMinor: Double, rotation: Double)
    /// A star alternating between `outerRadius` and `innerRadius` across
    /// `pointCount` points, with `rotation` in radians.
    case star(center: Point, outerRadius: Double, innerRadius: Double,
              rotation: Double, pointCount: Int)

    /// A closed (or, for a line, open) polyline outline suitable for rendering.
    public func outline(samples: Int = 96) -> [Point] {
        switch self {
        case let .line(a, b):
            return [a, b]
        case let .rectangle(corners):
            return corners
        case let .triangle(verts):
            return verts
        case let .ellipse(center, major, minor, rotation):
            let c = Double.cos(rotation), s = Double.sin(rotation)
            return (0..<samples).map { i in
                let t = 2 * Double.pi * Double(i) / Double(samples)
                let x = major * Double.cos(t), y = minor * Double.sin(t)
                return Point(x: center.x + x * c - y * s,
                             y: center.y + x * s + y * c)
            }
        case let .star(center, outer, inner, rotation, pointCount):
            var pts: [Point] = []
            let steps = pointCount * 2
            for i in 0..<steps {
                let a = rotation - .pi / 2 + Double(i) * .pi / Double(pointCount)
                let r = (i % 2 == 0) ? outer : inner
                pts.append(Point(x: center.x + r * Double.cos(a),
                                 y: center.y + r * Double.sin(a)))
            }
            return pts
        }
    }
}

/// Internal classifier label / gate key. Unlike public `Shape`, this has no fitted geometry.
enum ShapeKind: String, CaseIterable, Sendable {
    case line
    case rectangle
    case triangle
    case ellipse
    case star
}
