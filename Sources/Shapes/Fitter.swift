import RealModule

/// Stage-2 geometric fitters (port of the Python `fitter.py`).
///
/// Each fitter takes the raw stroke points and returns clean vector geometry
/// plus a normalized fit residual (RMS point-to-shape distance / bbox diagonal),
/// which the recognizer's gates use to verify the neural-net's proposal. Math
/// is the portable ``V2`` type (no `simd`), so it runs identically everywhere.
enum Fitter {
    static func fit(_ shape: ShapeKind, points: [Point], snap config: SnapConfig)
        -> (Shape, Double) {
        // Resample to uniform arc length first: raw input points are unevenly
        // spaced (fast straight runs, slow curves), which biases centroid- and
        // moment-based fits (notably the ellipse/star center).
        let pts = resampleUniform(points.map { V2($0.x, $0.y) }, count: 256)
        let (fitted, residual): (Shape, Double)
        switch shape {
        case .line: (fitted, residual) = fitLine(pts)
        case .rectangle: (fitted, residual) = fitRectangle(pts)
        case .triangle: (fitted, residual) = fitTriangle(pts)
        case .ellipse: (fitted, residual) = fitEllipse(pts)
        case .star: (fitted, residual) = fitStar(pts)
        }
        // Gate on the accurate raw-fit residual; clean the output geometry.
        return (snap(fitted, config: config), residual)
    }

    private static func resampleUniform(_ p: [V2], count: Int) -> [V2] {
        guard p.count > 2, count > 1 else { return p }
        var cum = [0.0]
        cum.reserveCapacity(p.count)
        for i in 1..<p.count { cum.append(cum[i - 1] + (p[i] - p[i - 1]).length) }
        let total = cum[cum.count - 1]
        guard total > 0 else { return p }
        var out = [V2]()
        out.reserveCapacity(count)
        var j = 0
        for i in 0..<count {
            let target = total * Double(i) / Double(count - 1)
            while j < p.count - 2 && cum[j + 1] < target { j += 1 }
            let seg = cum[j + 1] - cum[j]
            let t = seg > 0 ? (target - cum[j]) / seg : 0
            out.append(p[j] + (p[j + 1] - p[j]) * t)
        }
        return out
    }

    // MARK: Residual helpers

    private static func bboxDiag(_ p: [V2]) -> Double {
        var lo = p[0], hi = p[0]
        for v in p { lo = vmin(lo, v); hi = vmax(hi, v) }
        let d = (hi - lo).length
        return d > 0 ? d : 1
    }

    private static func ptSegDist(_ q: V2, _ a: V2, _ b: V2) -> Double {
        let ab = b - a
        let l2 = dot(ab, ab)
        if l2 == 0 { return (q - a).length }
        let t = max(0.0, min(1.0, dot(q - a, ab) / l2))
        return (q - (a + t * ab)).length
    }

    private static func residual(_ stroke: [V2], _ poly: [V2], closed: Bool) -> Double {
        var ring = poly
        if closed, let f = poly.first { ring.append(f) }
        var sumSq = 0.0
        for q in stroke {
            var best = Double.greatestFiniteMagnitude
            for i in 0..<(ring.count - 1) {
                best = min(best, ptSegDist(q, ring[i], ring[i + 1]))
            }
            sumSq += best * best
        }
        let rms = (sumSq / Double(stroke.count)).squareRoot()
        return rms / bboxDiag(stroke)
    }

    private static func cgp(_ v: V2) -> Point { Point(x: v.x, y: v.y) }
    private static func centroid(_ p: [V2]) -> V2 { p.reduce(V2(0, 0), +) / Double(p.count) }

    // MARK: Line — PCA principal axis

    private static func fitLine(_ pts: [V2]) -> (Shape, Double) {
        let c = centroid(pts)
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in pts {
            let d = p - c
            sxx += d.x * d.x; sxy += d.x * d.y; syy += d.y * d.y
        }
        let dir = symEig2x2Major(sxx, sxy, syy)
        var lo = Double.greatestFiniteMagnitude, hi = -Double.greatestFiniteMagnitude
        for p in pts {
            let t = dot(p - c, dir)
            lo = min(lo, t); hi = max(hi, t)
        }
        let a = c + lo * dir, b = c + hi * dir
        return (.line(from: cgp(a), to: cgp(b)), residual(pts, [a, b], closed: false))
    }

    // MARK: Rectangle — minimum-area oriented box

    private static func fitRectangle(_ pts: [V2]) -> (Shape, Double) {
        // Minimum-area oriented bounding box via rotating calipers over the
        // convex hull; rotation = atan2 of the best box edge direction. PCA of
        // the perimeter is unstable for near-squares (it picks the diagonal), so
        // we keep the tightest hull-edge-aligned box instead.
        let hull = convexHull(pts)
        if hull.count < 3 { return fitLine(pts) }
        var best: (area: Double, corners: [V2])?
        for i in 0..<hull.count {
            let edge = hull[(i + 1) % hull.count] - hull[i]
            let ang = Double.atan2(y: edge.y, x: edge.x)
            let r = Mat2.rotation(-ang)
            var lo = V2(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
            var hi = V2(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
            for h in hull { let p = r * h; lo = vmin(lo, p); hi = vmax(hi, p) }
            let area = (hi.x - lo.x) * (hi.y - lo.y)
            if best == nil || area < best!.area {
                let cr = [V2(lo.x, lo.y), V2(hi.x, lo.y), V2(hi.x, hi.y), V2(lo.x, hi.y)]
                let back = Mat2.rotation(ang)
                best = (area, cr.map { back * $0 })
            }
        }
        let corners = best!.corners
        return (.rectangle(corners: corners.map(cgp)), residual(pts, corners, closed: true))
    }

    // MARK: Triangle — largest-area triangle over the hull

    private static func fitTriangle(_ pts: [V2]) -> (Shape, Double) {
        var hull = convexHull(pts)
        if hull.count < 3 { return fitLine(pts) }
        if hull.count > 36 {
            let idx = (0..<36).map { Int((Double($0) * Double(hull.count - 1) / 35.0).rounded()) }
            var seen = Set<Int>(); hull = idx.filter { seen.insert($0).inserted }.map { hull[$0] }
        }
        var best = -1.0
        var tri = [hull[0], hull[1], hull[2]]
        for i in 0..<hull.count {
            for j in (i + 1)..<hull.count {
                for k in (j + 1)..<hull.count {
                    let area = abs(crossZ(hull[j] - hull[i], hull[k] - hull[i])) * 0.5
                    if area > best { best = area; tri = [hull[i], hull[j], hull[k]] }
                }
            }
        }
        return (.triangle(vertices: tri.map(cgp)), residual(pts, tri, closed: true))
    }

    // MARK: Ellipse — principal axis + projected extents

    private static func fitEllipse(_ pts: [V2]) -> (Shape, Double) {
        // Principal-axis direction from the covariance, then center and semi-axes
        // from the min/max projection onto those axes (an ellipse touches its
        // bounding box at the axis endpoints). Center and axes are sampling-
        // independent, avoiding the centroid/variance bias of a pure moment fit.
        let c = centroid(pts)
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for p in pts {
            let d = p - c
            sxx += d.x * d.x; sxy += d.x * d.y; syy += d.y * d.y
        }
        let (_, _, v1, _) = symEig2x2Full(sxx, sxy, syy)
        let u = v1, v = V2(-v1.y, v1.x)
        var uLo = Double.greatestFiniteMagnitude, uHi = -uLo
        var vLo = Double.greatestFiniteMagnitude, vHi = -vLo
        for p in pts {
            let tu = dot(p - c, u), tv = dot(p - c, v)
            uLo = min(uLo, tu); uHi = max(uHi, tu)
            vLo = min(vLo, tv); vHi = max(vHi, tv)
        }
        let center = c + (uLo + uHi) / 2 * u + (vLo + vHi) / 2 * v
        let major = (uHi - uLo) / 2, minor = (vHi - vLo) / 2
        let rotation = Double.atan2(y: u.y, x: u.x)
        if major <= 0 || minor <= 0 || !major.isFinite || !minor.isFinite {
            let r = pts.reduce(0.0) { $0 + ($1 - c).length } / Double(pts.count)
            let poly = ellipseOutline(c, r, r, 0)
            return (.ellipse(center: cgp(c), semiMajor: r, semiMinor: r,
                             rotation: 0), residual(pts, poly, closed: true))
        }
        let poly = ellipseOutline(center, major, minor, rotation)
        return (.ellipse(center: cgp(center), semiMajor: major, semiMinor: minor,
                         rotation: rotation), residual(pts, poly, closed: true))
    }

    private static func ellipseOutline(_ c: V2, _ major: Double, _ minor: Double,
                                       _ rotation: Double) -> [V2] {
        let cc = Double.cos(rotation), ss = Double.sin(rotation)
        return (0..<160).map { i -> V2 in
            let t = 2 * Double.pi * Double(i) / 160
            let x = major * Double.cos(t), y = minor * Double.sin(t)
            return c + V2(x * cc - y * ss, x * ss + y * cc)
        }
    }

    // MARK: Star — instantiate template at a fitted pose

    private static func fitStar(_ pts: [V2]) -> (Shape, Double) {
        let center = centroid(pts)
        let radii = pts.map { ($0 - center).length }

        // Rotation: radius-weighted circular mean in 5x angle space (5-fold
        // symmetry). Template outer tip 0 sits at angle -pi/2 + rotation, so
        // 5*(-pi/2 + rotation) == phase  =>  rotation = phase/5 + pi/2.
        var sc = 0.0, ss = 0.0
        for (i, p) in pts.enumerated() {
            let a = Double.atan2(y: (p - center).y, x: (p - center).x)
            let w = radii[i] * radii[i]
            sc += w * Double.cos(5 * a); ss += w * Double.sin(5 * a)
        }
        let rot0 = Double.atan2(y: ss, x: sc) / 5 + Double.pi / 2

        // Size: outer radius from the largest radii (the tips); template fixes
        // the inner/outer ratio at 0.4.
        let sorted = radii.sorted()
        let topCount = max(1, sorted.count / 5)
        let outer = sorted.suffix(topCount).reduce(0, +) / Double(topCount)
        let inner = outer * 0.4

        // The 5x mean is periodic in 72°; disambiguate with a half-period offset.
        var best = (Double.greatestFiniteMagnitude, rot0)
        for angle in [rot0, rot0 + Double.pi / 5] {
            let res = residual(pts, starVertices(center, outer, inner, angle), closed: true)
            if res < best.0 { best = (res, angle) }
        }
        return (.star(center: cgp(center), outerRadius: outer,
                      innerRadius: inner, rotation: best.1, pointCount: 5),
                best.0)
    }

    private static func starVertices(_ center: V2, _ outer: Double, _ inner: Double,
                                     _ rotation: Double) -> [V2] {
        (0..<10).map { i in
            let a = rotation - Double.pi / 2 + Double(i) * Double.pi / 5
            let r = i % 2 == 0 ? outer : inner
            return center + V2(r * Double.cos(a), r * Double.sin(a))
        }
    }

    // MARK: Convex hull (monotone chain)

    private static func convexHull(_ points: [V2]) -> [V2] {
        var pts = Array(Set(points.map { HashV2(($0.x * 1e6).rounded() / 1e6,
                                               ($0.y * 1e6).rounded() / 1e6) })).map(\.v)
        if pts.count <= 2 { return pts }
        pts.sort { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func cross(_ o: V2, _ a: V2, _ b: V2) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [V2] = []
        for p in pts {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [V2] = []
        for p in pts.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }

    // MARK: small linear algebra

    /// Major eigenvector of the symmetric 2x2 [[a,b],[b,c]].
    private static func symEig2x2Major(_ a: Double, _ b: Double, _ c: Double) -> V2 {
        let (_, _, v1, _) = symEig2x2Full(a, b, c)
        return v1
    }

    /// Returns (largerEigval, smallerEigval, vecForLarger, vecForSmaller).
    private static func symEig2x2Full(_ a: Double, _ b: Double, _ c: Double)
        -> (Double, Double, V2, V2) {
        let tr = a + c
        let disc = (((a - c) / 2) * ((a - c) / 2) + b * b).squareRoot()
        let l1 = tr / 2 + disc
        let l2 = tr / 2 - disc
        func vec(_ l: Double) -> V2 {
            let v = abs(b) > 1e-15 ? V2(l - c, b) : (a >= c ? V2(1, 0) : V2(0, 1))
            let n = v.length
            return n > 0 ? v / n : V2(1, 0)
        }
        return (l1, l2, vec(l1), vec(l2))
    }
}

/// Hashable wrapper so the convex hull can dedupe rounded points in a `Set`
/// (portable; `V2` stays a plain arithmetic value type).
private struct HashV2: Hashable {
    let v: V2
    init(_ x: Double, _ y: Double) { v = V2(x, y) }
    static func == (a: HashV2, b: HashV2) -> Bool { a.v == b.v }
    func hash(into h: inout Hasher) { h.combine(v.x); h.combine(v.y) }
}
