import RealModule

/// How Shapes snaps a recognized shape's rotation.
public enum Rotation: Sendable, Equatable {
    /// The default. Shapes rounds rotations to 15° steps and snaps lines and
    /// edges within 5° of horizontal or vertical onto the axis.
    case snapped
    /// Shapes removes rotation. Rectangles and ellipses align with the axes,
    /// each polygon has a horizontal edge or a vertex straight up, and each
    /// star has a tip straight up.
    case upright
    /// Shapes keeps the fitted shape as drawn, and skips the snapping to
    /// circles, squares, and regular polygons.
    case free
}

/// Snapping after the fit. A shape within a tolerance of regular becomes
/// regular, and then its rotation follows ``Rotation``. The gates check the
/// residual of the fit before snapping, so snapping can't make Shapes accept a
/// stroke it rejected.
enum Snapping {
    /// Lines and edges within this many degrees of horizontal or vertical snap onto the axis.
    static let axisDegrees = 5.0
    /// Rotation step for `.snapped`.
    static let stepDegrees = 15.0
    /// `minAxis / maxAxis` at or above which an ellipse becomes a circle.
    static let circleRatio = 0.85
    /// `minSide / maxSide` at or above which a rectangle becomes a square.
    static let squareRatio = 0.9
    /// `(maxSide - minSide) / maxSide` at or below which a polygon becomes regular.
    static let regularSpread = 0.15
    /// `(longer - shorter) / longer` for two legs at or below which a triangle becomes isosceles.
    static let isoscelesSpread = 0.1

    static func apply(_ shape: Shape, rotation: Rotation) -> Shape {
        if rotation == .free { return shape }
        let upright = rotation == .upright
        switch shape {
        case let .line(a, b):
            let (p, q) = axisSnapped(v(a), v(b))
            return .line(from: pt(p), to: pt(q))
        case let .rectangle(corners):
            return .rectangle(corners: rectangle(corners.map(v), upright: upright).map(pt))
        case let .ellipse(c, a, b, rot):
            return ellipse(c, a, b, rot, upright: upright)
        case let .triangle(vs):
            return .triangle(vertices: triangle(vs.map(v), upright: upright).map(pt))
        case let .diamond(vs):
            return .diamond(vertices: diamond(vs.map(v), upright: upright).map(pt))
        case let .pentagon(vs):
            return .pentagon(vertices: polygon(vs.map(v), upright: upright, uprightPhase: -Double.pi / 2).map(pt))
        case let .hexagon(vs):
            return .hexagon(vertices: polygon(vs.map(v), upright: upright, uprightPhase: 0).map(pt))
        case let .star(c, outer, inner, rot, count):
            let period = 2 * Double.pi / Double(count)
            let r = upright ? 0 : step(rot)
            return .star(center: c, outerRadius: outer, innerRadius: inner,
                         rotation: (r.truncatingRemainder(dividingBy: period) + period).truncatingRemainder(dividingBy: period),
                         pointCount: count)
        case .curve, .arrow, .heart, .cloud, .scribble:
            return shape
        }
    }

    // MARK: Helpers

    private static func v(_ p: Point) -> V2 { V2(p.x, p.y) }
    private static func pt(_ p: V2) -> Point { Point(x: p.x, y: p.y) }
    private static func angle(_ d: V2) -> Double { Double.atan2(y: d.y, x: d.x) }

    /// `angle` to the nearest multiple of `period`.
    private static func nearest(_ angle: Double, _ period: Double) -> Double {
        (angle / period).rounded() * period
    }

    private static func step(_ angle: Double) -> Double {
        nearest(angle, stepDegrees * Double.pi / 180)
    }

    /// The turn from `angle` onto the nearest axis, or nil when the turn is
    /// larger than `axisDegrees`.
    private static func toAxis(_ angle: Double) -> Double? {
        let target = nearest(angle, Double.pi / 2)
        return abs(angle - target) <= axisDegrees * Double.pi / 180 ? target - angle : nil
    }

    private static func rotate(_ ps: [V2], by a: Double, about c: V2) -> [V2] {
        let m = Mat2.rotation(a)
        return ps.map { c + m * ($0 - c) }
    }

    private static func centroid(_ ps: [V2]) -> V2 { ps.reduce(V2(0, 0), +) / Double(ps.count) }

    private static func axisSnapped(_ a: V2, _ b: V2) -> (V2, V2) {
        guard let turn = toAxis(angle(b - a)) else { return (a, b) }
        let r = rotate([a, b], by: turn, about: (a + b) / 2)
        return (r[0], r[1])
    }

    // MARK: Kinds

    private static func ellipse(_ c: Point, _ a: Double, _ b: Double, _ rot: Double, upright: Bool) -> Shape {
        if a > 0 && min(a, b) / max(a, b) >= circleRatio {
            let r = (a + b) / 2
            return .ellipse(center: c, semiMajor: r, semiMinor: r, rotation: 0)
        }
        var r = upright ? nearest(rot, Double.pi / 2) : step(rot)
        // keep the rotation in (-pi/2, pi/2]
        while r <= -Double.pi / 2 { r += Double.pi }
        while r > Double.pi / 2 { r -= Double.pi }
        return .ellipse(center: c, semiMajor: a, semiMinor: b, rotation: r)
    }

    private static func rectangle(_ p: [V2], upright: Bool) -> [V2] {
        guard p.count == 4 else { return p }
        let c = centroid(p)
        var w = (p[1] - p[0]).length, h = (p[3] - p[0]).length
        let a = angle(p[1] - p[0])
        if max(w, h) > 0 && min(w, h) / max(w, h) >= squareRatio { w = (w + h) / 2; h = w }
        let r = upright ? nearest(a, Double.pi / 2) : step(a)
        let m = Mat2.rotation(r)
        return [V2(-w / 2, -h / 2), V2(w / 2, -h / 2), V2(w / 2, h / 2), V2(-w / 2, h / 2)].map { c + m * $0 }
    }

    /// Makes the triangle equilateral or isosceles when it's close to one, then
    /// turns its edge nearest an axis onto that axis: within the threshold for
    /// `.snapped`, always for `.upright`.
    private static func triangle(_ p: [V2], upright: Bool) -> [V2] {
        guard p.count == 3 else { return p }
        let sides = [(p[1] - p[0]).length, (p[2] - p[1]).length, (p[0] - p[2]).length]
        var out = p
        if let hi = sides.max(), let lo = sides.min(), hi > 0, (hi - lo) / hi <= regularSpread {
            out = regular(p)
        } else {
            out = isosceles(p) ?? p
        }
        let edges = (0..<3).map { out[($0 + 1) % 3] - out[$0] }
        let turns = edges.map { nearest(angle($0), Double.pi / 2) - angle($0) }
        let best = turns.indices.min { abs(turns[$0]) < abs(turns[$1]) }!
        if upright {
            // turn the most horizontal edge flat
            let horizontal = edges.map { nearest(angle($0), Double.pi) - angle($0) }
            let i = horizontal.indices.min { abs(horizontal[$0]) < abs(horizontal[$1]) }!
            return rotate(out, by: horizontal[i], about: centroid(out))
        }
        return abs(turns[best]) <= axisDegrees * Double.pi / 180 ? rotate(out, by: turns[best], about: centroid(out)) : out
    }

    /// Makes the two most similar legs equal, keeping their shared apex.
    private static func isosceles(_ p: [V2]) -> [V2]? {
        var best: (Int, Double)?
        for apex in 0..<3 {
            let l1 = (p[(apex + 1) % 3] - p[apex]).length, l2 = (p[(apex + 2) % 3] - p[apex]).length
            let spread = abs(l1 - l2) / max(l1, l2, 1e-12)
            if best == nil || spread < best!.1 { best = (apex, spread) }
        }
        guard let (apex, spread) = best, spread <= isoscelesSpread else { return nil }
        let a = p[apex]
        let l = ((p[(apex + 1) % 3] - a).length + (p[(apex + 2) % 3] - a).length) / 2
        var out = p
        for k in [(apex + 1) % 3, (apex + 2) % 3] {
            let d = p[k] - a
            out[k] = a + d / max(d.length, 1e-12) * l
        }
        return out
    }

    /// A regular polygon around the centroid, with the mean radius, the
    /// vertices' circular-mean phase, and the original vertex order and winding.
    private static func regular(_ p: [V2]) -> [V2] {
        let k = p.count, c = centroid(p)
        let r = p.map { ($0 - c).length }.reduce(0, +) / Double(k)
        let wind: Double = crossZ(p[1] - p[0], p[2] - p[1]) >= 0 ? 1 : -1
        var sx = 0.0, sy = 0.0
        for (i, q) in p.enumerated() {
            let a = angle(q - c) - wind * Double(i) * 2 * Double.pi / Double(k)
            sx += Double.cos(a); sy += Double.sin(a)
        }
        let base = Double.atan2(y: sy, x: sx)
        return (0..<k).map { i in
            let a = base + wind * Double(i) * 2 * Double.pi / Double(k)
            return c + V2(Double.cos(a), Double.sin(a)) * r
        }
    }

    /// The phase of a k-gon's vertices (any vertex's angle, modulo 2 pi / k).
    private static func phase(_ p: [V2]) -> Double {
        let k = Double(p.count), c = centroid(p)
        var sx = 0.0, sy = 0.0
        for q in p { let a = angle(q - c) * k; sx += Double.cos(a); sy += Double.sin(a) }
        return Double.atan2(y: sy, x: sx) / k
    }

    private static func polygon(_ p: [V2], upright: Bool, uprightPhase: Double) -> [V2] {
        let k = p.count
        guard k >= 3 else { return p }
        let sides = (0..<k).map { (p[($0 + 1) % k] - p[$0]).length }
        var out = p
        if let hi = sides.max(), let lo = sides.min(), hi > 0, (hi - lo) / hi <= regularSpread {
            out = regular(p)
        }
        let period = 2 * Double.pi / Double(k)
        let ph = phase(out)
        // Upright puts a vertex at `uprightPhase` (a pentagon's top) or halfway
        // between (a pentagon pointing down, a flat-topped hexagon), whichever
        // is nearer.
        let target = upright
            ? uprightPhase + nearest(ph - uprightPhase, period / 2)
            : step(ph)
        return rotate(out, by: target - ph, about: centroid(out))
    }

    /// A rhombus with perpendicular diagonals. `.upright` turns the diagonals
    /// onto the axes, and `.snapped` rounds their angle to a 15° step.
    private static func diamond(_ p: [V2], upright: Bool) -> [V2] {
        guard p.count == 4 else { return p }
        let c = centroid(p)
        let d1 = (p[0] - p[2]) / 2
        var d2 = (p[1] - p[3]) / 2
        // make the second diagonal perpendicular to the first, keeping its
        // length and side
        let n = V2(-d1.y, d1.x) / max(d1.length, 1e-12)
        d2 = n * (dot(d2, n) >= 0 ? d2.length : -d2.length)
        var out = [c + d1, c + d2, c - d1, c - d2]
        let a = angle(d1)
        let target = upright ? nearest(a, Double.pi / 2) : step(a)
        out = rotate(out, by: target - a, about: c)
        return out
    }
}
