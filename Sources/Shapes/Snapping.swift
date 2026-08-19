import RealModule

/// Geometry regularization ("smart shape" snapping). After the fitter produces
/// an accurate fit, these cheap snaps clean the output to nice axes, angles,
/// circles, and squares.
struct SnapConfig: Sendable {
    /// Snap a line to the horizontal/vertical axis within this angle (degrees).
    var lineAxisThresholdDeg: Double = 5
    /// Snap an ellipse to a circle when `minAxis / maxAxis >= 1 - ratio`.
    var ellipseCircleRatio: Double = 0.25
    /// Snap ellipse rotation to multiples of this (degrees).
    var ellipseRotationIncrementDeg: Double = 15
    /// Snap a rectangle to a square when `minSide / maxSide >= 1 - ratio`.
    var rectangleSquareRatio: Double = 0.25
    /// Snap rectangle rotation to multiples of this (degrees).
    var rectangleRotationIncrementDeg: Double = 15
    /// Snap a triangle's base edge to the horizontal/vertical axis within this
    /// angle (degrees).
    var triangleAxisThresholdDeg: Double = 5
    /// Snap a triangle to equilateral when `(maxSide - minSide) / maxSide <= ratio`.
    var triangleEquilateralRatio: Double = 0.25
    /// Snap a triangle to isosceles when its two most-equal legs are within this
    /// ratio.
    var triangleIsoscelesRatio: Double = 0.25

    /// Standard defaults.
    static let standard = SnapConfig()

    /// No regularization (thresholds and increments disabled).
    static let disabled = SnapConfig(
        lineAxisThresholdDeg: 0, ellipseCircleRatio: 0, ellipseRotationIncrementDeg: 0,
        rectangleSquareRatio: 0, rectangleRotationIncrementDeg: 0,
        triangleAxisThresholdDeg: 0, triangleEquilateralRatio: 0, triangleIsoscelesRatio: 0
    )
}

extension Fitter {
    /// Apply regularization snapping to a fitted shape. Geometry-only cleanup;
    /// the caller keeps the residual from the raw (pre-snap) fit for gating.
    static func snap(_ shape: Shape, config c: SnapConfig) -> Shape {
        switch shape {
        case let .line(from, to):
            return snapLine(from, to, c)
        case let .rectangle(corners):
            return snapRectangle(corners, c)
        case let .triangle(verts):
            return snapTriangle(verts, c)
        case let .ellipse(center, major, minor, rotation):
            return snapEllipse(center, major, minor, rotation, c)
        case .star:
            return shape  // template already regular
        }
    }

    // MARK: Angle helpers

    private static func snapToIncrement(_ angle: Double, incrementDeg: Double) -> Double {
        guard incrementDeg > 0 else { return angle }
        let inc = incrementDeg * .pi / 180
        return (angle / inc).rounded() * inc
    }

    /// If `angle` is within `thresholdDeg` of the nearest multiple of 90°, return
    /// that snapped angle; otherwise `nil`.
    private static func snapToAxis(_ angle: Double, thresholdDeg: Double) -> Double? {
        guard thresholdDeg > 0 else { return nil }
        let quarter = Double.pi / 2
        let nearest = (angle / quarter).rounded() * quarter
        return abs(angle - nearest) <= thresholdDeg * .pi / 180 ? nearest : nil
    }

    private static func v2(_ p: Point) -> V2 { V2(p.x, p.y) }
    private static func point(_ v: V2) -> Point { Point(x: v.x, y: v.y) }

    // MARK: Line

    private static func snapLine(_ from: Point, _ to: Point, _ c: SnapConfig) -> Shape {
        let a = v2(from), b = v2(to)
        let ang = Double.atan2(y: b.y - a.y, x: b.x - a.x)
        guard let snapped = snapToAxis(ang, thresholdDeg: c.lineAxisThresholdDeg) else {
            return .line(from: from, to: to)
        }
        let mid = (a + b) / 2
        let half = (b - a).length / 2
        let dir = V2(Double.cos(snapped), Double.sin(snapped))
        return .line(from: point(mid - half * dir), to: point(mid + half * dir))
    }

    // MARK: Ellipse

    private static func snapEllipse(
        _ center: Point, _ major: Double, _ minor: Double, _ rotation: Double,
        _ c: SnapConfig
    ) -> Shape {
        let maj = major, min_ = minor
        let hi = Swift.max(maj, min_), lo = Swift.min(maj, min_)
        if c.ellipseCircleRatio > 0, hi > 0, lo / hi >= 1 - c.ellipseCircleRatio {
            let r = (maj + min_) / 2
            return .ellipse(center: center, semiMajor: r, semiMinor: r, rotation: 0)
        }
        let rot = snapToIncrement(rotation, incrementDeg: c.ellipseRotationIncrementDeg)
        return .ellipse(center: center, semiMajor: major, semiMinor: minor, rotation: rot)
    }

    // MARK: Rectangle

    private static func snapRectangle(_ corners: [Point], _ c: SnapConfig) -> Shape {
        guard corners.count == 4 else { return .rectangle(corners: corners) }
        let p = corners.map(v2)
        let center = (p[0] + p[1] + p[2] + p[3]) / 4
        var w = (p[1] - p[0]).length
        var h = (p[3] - p[0]).length
        var ang = Double.atan2(y: (p[1] - p[0]).y, x: (p[1] - p[0]).x)

        let hi = Swift.max(w, h), lo = Swift.min(w, h)
        if c.rectangleSquareRatio > 0, hi > 0, lo / hi >= 1 - c.rectangleSquareRatio {
            let s = (w + h) / 2
            w = s; h = s
        }
        ang = snapToIncrement(ang, incrementDeg: c.rectangleRotationIncrementDeg)

        let r = Mat2.rotation(ang)
        let hw = w / 2, hh = h / 2
        let local = [V2(-hw, -hh), V2(hw, -hh), V2(hw, hh), V2(-hw, hh)]
        return .rectangle(corners: local.map { point(center + r * $0) })
    }

    // MARK: Triangle

    private static func snapTriangle(_ verts: [Point], _ c: SnapConfig) -> Shape {
        guard verts.count == 3 else { return .triangle(vertices: verts) }
        var v = verts.map(v2)
        let centroid = (v[0] + v[1] + v[2]) / 3

        let lAB = (v[0] - v[1]).length
        let lBC = (v[1] - v[2]).length
        let lCA = (v[2] - v[0]).length
        let sides = [lAB, lBC, lCA]
        let mx = sides.max() ?? 0, mn = sides.min() ?? 0

        if c.triangleEquilateralRatio > 0, mx > 0, (mx - mn) / mx <= c.triangleEquilateralRatio {
            v = makeEquilateral(v, centroid: centroid)
        } else if c.triangleIsoscelesRatio > 0 {
            v = makeIsosceles(v, legs: [lAB, lBC, lCA], ratio: c.triangleIsoscelesRatio) ?? v
        }

        return alignTriangleToAxis(v, thresholdDeg: c.triangleAxisThresholdDeg)
    }

    private static func makeEquilateral(_ v: [V2], centroid c: V2) -> [V2] {
        let r = ((v[0] - c).length + (v[1] - c).length + (v[2] - c).length) / 3
        // Circular mean of (angle_i - i*120°) gives a stable base orientation.
        var sx = 0.0, sy = 0.0
        for i in 0..<3 {
            let a = Double.atan2(y: v[i].y - c.y, x: v[i].x - c.x) - Double(i) * 2 * Double.pi / 3
            sx += Double.cos(a); sy += Double.sin(a)
        }
        let base = Double.atan2(y: sy, x: sx)
        return (0..<3).map { i in
            let a = base + Double(i) * 2 * Double.pi / 3
            return c + r * V2(Double.cos(a), Double.sin(a))
        }
    }

    /// Equalize the two most-similar legs about their shared apex.
    private static func makeIsosceles(_ v: [V2], legs: [Double], ratio: Double) -> [V2]? {
        // Apex candidates: (apex, leg1, leg2) by vertex index.
        let cand: [(apex: Int, b: Int, cc: Int, l1: Double, l2: Double)] = [
            (0, 1, 2, legs[0], legs[2]),  // v0 between edges v0v1, v2v0
            (1, 0, 2, legs[0], legs[1]),  // v1 between edges v0v1, v1v2
            (2, 0, 1, legs[2], legs[1]),  // v2 between edges v2v0, v1v2
        ]
        let best = cand.min { rel($0.l1, $0.l2) < rel($1.l1, $1.l2) }!
        guard rel(best.l1, best.l2) <= ratio else { return nil }
        let apex = v[best.apex]
        let avg = (best.l1 + best.l2) / 2
        func leg(_ to: Int) -> V2 {
            let d = v[to] - apex
            let n = d.length
            return apex + (n > 0 ? d / n : d) * avg
        }
        var out = v
        out[best.b] = leg(best.b)
        out[best.cc] = leg(best.cc)
        return out
    }

    private static func rel(_ a: Double, _ b: Double) -> Double {
        let m = Swift.max(a, b)
        return m > 0 ? abs(a - b) / m : 0
    }

    /// Rotate the triangle about its centroid so its longest edge aligns to the
    /// nearest axis, when within threshold.
    private static func alignTriangleToAxis(_ v: [V2], thresholdDeg: Double) -> Shape {
        let edges = [(v[0], v[1]), (v[1], v[2]), (v[2], v[0])]
        let longest = edges.max { ($0.1 - $0.0).length < ($1.1 - $1.0).length }!
        let dir = longest.1 - longest.0
        let ang = Double.atan2(y: dir.y, x: dir.x)
        guard let snapped = snapToAxis(ang, thresholdDeg: thresholdDeg) else {
            return .triangle(vertices: v.map(point))
        }
        let centroid = (v[0] + v[1] + v[2]) / 3
        let r = Mat2.rotation(snapped - ang)
        let out = v.map { centroid + r * ($0 - centroid) }
        return .triangle(vertices: out.map(point))
    }
}
