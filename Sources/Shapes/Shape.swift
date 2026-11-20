import RealModule

/// A recognized shape, in the same coordinates as the input stroke.
///
/// The kinds and their field names are the same in Swift, Kotlin, and
/// TypeScript. You can draw any shape from ``outline(samples:)``. For an arrow,
/// ``arrowheads(length:)`` returns the heads.
public enum Shape: Sendable, Equatable {
    /// A straight connector.
    case line(from: Point, to: Point)
    /// A curved connector: a cubic Bezier from `from` to `to`.
    case curve(from: Point, control1: Point, control2: Point, to: Point)
    /// A connector with a drawn head at one or both ends. The shaft is a cubic
    /// Bezier. A straight arrow has its controls on the line.
    case arrow(from: Point, control1: Point, control2: Point, to: Point,
               startHead: Bool, endHead: Bool)
    /// Four corners in order around the perimeter.
    case rectangle(corners: [Point])
    /// An ellipse. `rotation`, in radians, is the angle of the `semiMajor` axis from +x.
    case ellipse(center: Point, semiMajor: Double, semiMinor: Double, rotation: Double)
    /// Three vertices.
    case triangle(vertices: [Point])
    /// A rhombus: four vertices in order around the perimeter.
    case diamond(vertices: [Point])
    /// Five vertices in order around the perimeter.
    case pentagon(vertices: [Point])
    /// Six vertices in order around the perimeter.
    case hexagon(vertices: [Point])
    /// A star with `pointCount` tips, alternating between `outerRadius` and
    /// `innerRadius`. At `rotation` 0, a tip points straight up.
    case star(center: Point, outerRadius: Double, innerRadius: Double,
              rotation: Double, pointCount: Int)
    /// A heart that fills a `width` by `height` box around `center`, with its point down.
    case heart(center: Point, width: Double, height: Double)
    /// A cloud. `outline` is the closed outline of its bumps.
    case cloud(outline: [Point])
    /// The erase gesture. `hull` is the convex hull of the scribble. To erase,
    /// delete the content inside the hull.
    case scribble(hull: [Point])
    /// A check mark: the end of the short arm, the corner, the end of the long arm.
    case check(start: Point, corner: Point, end: Point)
    /// A cross mark: two straight strokes, each from its upper end, the one
    /// whose upper end is further left first.
    case cross(firstFrom: Point, firstTo: Point, secondFrom: Point, secondTo: Point)
    /// A plus mark: two straight strokes, the more level one first from its
    /// left end, then the more upright one from its upper end.
    case plus(firstFrom: Point, firstTo: Point, secondFrom: Point, secondTo: Point)
    /// A bracket or brace: four points from its top end, through its two
    /// corners, to its other end.
    case bracket(points: [Point])
    /// A zigzag, such as a highlight: from `from` to `to`, `abs(amplitude)`
    /// wide across, with `2 * teeth` straight runs. The sign of `amplitude` is
    /// the side the zigzag starts on: positive on the left of the direction of
    /// travel on a y-down canvas, negative on the right.
    case zigzag(from: Point, to: Point, amplitude: Double, teeth: Double)

    /// What a shape is, without its geometry.
    public enum Kind: String, Sendable, CaseIterable, Hashable {
        case line, curve, arrow, rectangle, ellipse, triangle, diamond, pentagon, hexagon
        case star, heart, cloud, scribble
        case check, cross, bracket, zigzag, plus
    }

    public var kind: Kind {
        switch self {
        case .line: .line
        case .curve: .curve
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .triangle: .triangle
        case .diamond: .diamond
        case .pentagon: .pentagon
        case .hexagon: .hexagon
        case .star: .star
        case .heart: .heart
        case .cloud: .cloud
        case .scribble: .scribble
        case .check: .check
        case .cross: .cross
        case .plus: .plus
        case .bracket: .bracket
        case .zigzag: .zigzag
        }
    }

    /// Whether the outline is a closed loop (everything but connectors and marks).
    public var isClosed: Bool {
        switch self {
        case .line, .curve, .arrow, .check, .cross, .plus, .bracket, .zigzag: false
        default: true
        }
    }

    /// A polyline you can draw. A closed shape's outline doesn't repeat its
    /// first point. A connector's outline runs from start to end, and an
    /// arrow's outline is its shaft (see ``arrowheads(length:)``). A cross's or a
    /// plus's outline is its first stroke, then its second: draw it with
    /// ``paths(samples:)``. `samples` sets the number of points on curved outlines.
    public func outline(samples: Int = 64) -> [Point] {
        let n = max(samples, 8)
        switch self {
        case let .line(a, b):
            return [a, b]
        case let .curve(a, c1, c2, b), let .arrow(a, c1, c2, b, _, _):
            return Bezier.points(a, c1, c2, b, count: n)
        case let .rectangle(vs), let .triangle(vs), let .diamond(vs), let .pentagon(vs), let .hexagon(vs):
            return vs
        case let .ellipse(center, major, minor, rotation):
            let c = Double.cos(rotation), s = Double.sin(rotation)
            return (0..<n).map { i in
                let t = 2 * Double.pi * Double(i) / Double(n)
                let x = major * Double.cos(t), y = minor * Double.sin(t)
                return Point(x: center.x + x * c - y * s, y: center.y + x * s + y * c)
            }
        case let .star(center, outer, inner, rotation, count):
            return (0..<(2 * count)).map { i in
                let a = rotation - Double.pi / 2 + Double(i) * Double.pi / Double(count)
                let r = i % 2 == 0 ? outer : inner
                return Point(x: center.x + r * Double.cos(a), y: center.y + r * Double.sin(a))
            }
        case let .heart(center, width, height):
            return Templates.heart(center: V2(center.x, center.y), width: width, height: height, count: n)
                .map { Point(x: $0.x, y: $0.y) }
        case let .cloud(outline), let .scribble(outline):
            return outline
        case let .check(a, b, c):
            return [a, b, c]
        case let .cross(a, b, c, d), let .plus(a, b, c, d):
            return [a, b, c, d]
        case let .bracket(points):
            return points
        case let .zigzag(from, to, amplitude, teeth):
            return Templates.zigzag(from: V2(from.x, from.y), to: V2(to.x, to.y), amplitude: amplitude, teeth: teeth)
                .map { Point(x: $0.x, y: $0.y) }
        }
    }

    /// Every polyline to draw, apart from an arrow's heads: two for a cross or a plus, one
    /// (``outline(samples:)``) for every other shape.
    public func paths(samples: Int = 64) -> [[Point]] {
        switch self {
        case let .cross(a, b, c, d), let .plus(a, b, c, d): return [[a, b], [c, d]]
        default: break
        }
        return [outline(samples: samples)]
    }

    /// An arrow's heads, each an open polyline `[barb, tip, barb]` with barbs
    /// `length` long in canvas units. For any other kind, the array is empty.
    public func arrowheads(length: Double) -> [[Point]] {
        guard case let .arrow(a, c1, c2, b, start, end) = self else { return [] }
        var heads: [[Point]] = []
        func head(tip: Point, from: Point) -> [Point] {
            let d = V2(tip.x - from.x, tip.y - from.y)
            let u = d.length > 0 ? d / d.length : V2(1, 0)
            let back = V2(-u.x, -u.y)
            let spread = 0.45
            let l = Mat2.rotation(spread) * back, r = Mat2.rotation(-spread) * back
            let t = V2(tip.x, tip.y)
            return [t + l * length, t, t + r * length].map { Point(x: $0.x, y: $0.y) }
        }
        // each head points along the shaft, from the third of 33 samples in from that end
        let shaft = Bezier.points(a, c1, c2, b, count: 33)
        if start { heads.append(head(tip: a, from: shaft[2])) }
        if end { heads.append(head(tip: b, from: shaft[30])) }
        return heads
    }
}

/// Cubic Bezier sampling.
enum Bezier {
    static func point(_ p0: V2, _ p1: V2, _ p2: V2, _ p3: V2, _ t: Double) -> V2 {
        let u = 1 - t
        return p0 * (u * u * u) + p1 * (3 * u * u * t) + p2 * (3 * u * t * t) + p3 * (t * t * t)
    }

    static func points(_ a: Point, _ c1: Point, _ c2: Point, _ b: Point, count: Int) -> [Point] {
        let p0 = V2(a.x, a.y), p1 = V2(c1.x, c1.y), p2 = V2(c2.x, c2.y), p3 = V2(b.x, b.y)
        return (0..<count).map { i in
            let q = point(p0, p1, p2, p3, Double(i) / Double(count - 1))
            return Point(x: q.x, y: q.y)
        }
    }
}

/// Outlines with a fixed template.
enum Templates {
    /// A zigzag's vertices: `2 * teeth` runs (at least 2) across the line from
    /// `from` to `to`, alternating `amplitude / 2` to either side, the first to
    /// the left of the direction of travel on a y-down canvas.
    static func zigzag(from a: V2, to b: V2, amplitude: Double, teeth: Double) -> [V2] {
        let k = max(2, Int((2 * teeth).rounded(.toNearestOrEven)))
        let d = b - a
        let length = max(d.length, 1e-6)
        let normal = V2(-d.y / length, d.x / length)
        return (0...k).map { i -> V2 in
            let along = d * (Double(i) / Double(k))
            let side: Double = i % 2 == 0 ? -amplitude / 2 : amplitude / 2
            return a + along + normal * side
        }
    }

    /// The parametric heart x = 16 sin^3 t, y = -(13 cos t - 5 cos 2t -
    /// 2 cos 3t - cos 4t), scaled to the box, with its point down in y-down
    /// canvas space.
    static func heart(center: V2, width: Double, height: Double, count n: Int, closed: Bool = false) -> [V2] {
        let raw: [V2] = (0..<(closed ? n + 1 : n)).map { i in
            let t = 2 * Double.pi * Double(i) / Double(n)
            let s = Double.sin(t)
            return V2(16 * s * s * s,
                      -(13 * Double.cos(t) - 5 * Double.cos(2 * t) - 2 * Double.cos(3 * t) - Double.cos(4 * t)))
        }
        var lo = raw[0], hi = raw[0]
        for p in raw { lo = vmin(lo, p); hi = vmax(hi, p) }
        let mid = (lo + hi) / 2
        return raw.map { p in
            V2(center.x + (p.x - mid.x) / (hi.x - lo.x) * width,
               center.y + (p.y - mid.y) / (hi.y - lo.y) * height)
        }
    }
}
