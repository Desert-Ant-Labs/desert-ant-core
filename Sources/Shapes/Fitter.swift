import RealModule

/// The geometric fitters. Each fitter computes the clean shape for a stroke the
/// classifier labeled, from the stroke resampled to 128 points in canvas units.
///
/// Each fitter also computes a residual: the mean distance from the stroke to
/// the fitted outline, divided by the stroke's size. The kind's gate rejects a
/// stroke whose residual is too large. The fitters match the Python
/// implementation the model was evaluated with, and
/// `Tests/Fixtures/shapes-parity.json` holds that implementation's outputs.
enum Fitter {
    static let pointCount = 128

    struct Fit {
        let shape: Shape
        /// The polyline the residual is measured against. A closed outline
        /// repeats its first point, as the Python implementation's does.
        let outline: [V2]
        let residual: Double
    }

    /// Fit `kind` to a raw stroke. `head` is the model's per-point arrowhead
    /// probability on the 128 resampled points (only arrows read it).
    static func fit(_ kind: Shape.Kind, points: [Point], head: [Float], straightTolerance: Double = 0.06) -> Fit {
        let p = Preprocess.resampledFloat(points, count: pointCount)
        switch kind {
        case .line, .curve: return connector(p, tolerance: straightTolerance)
        case .arrow: return arrow(p, head: head, tolerance: straightTolerance)
        case .ellipse: return ellipse(p)
        case .rectangle: return rectangle(p)
        case .triangle: return convexPolygon(p, k: 3, kind: .triangle)
        case .diamond: return convexPolygon(p, k: 4, kind: .diamond)
        case .pentagon: return convexPolygon(p, k: 5, kind: .pentagon)
        case .hexagon: return convexPolygon(p, k: 6, kind: .hexagon)
        case .star: return star(p)
        case .heart: return heart(p)
        case .cloud: return cloud(p)
        case .scribble: return scribble(p)
        }
    }

    // MARK: - Helpers

    static func size(_ p: [V2]) -> Double {
        var lo = p[0], hi = p[0]
        for q in p { lo = vmin(lo, q); hi = vmax(hi, q) }
        return max(hi.x - lo.x, hi.y - lo.y, 1e-9)
    }

    /// Distance from each point to the polyline.
    static func distances(_ p: [V2], to poly: [V2]) -> [Double] {
        p.map { q in
            var best = Double.infinity
            for i in 0..<(poly.count - 1) {
                let a = poly[i], ab = poly[i + 1] - a
                let t = min(max(dot(q - a, ab) / max(dot(ab, ab), 1e-18), 0), 1)
                best = min(best, (q - (a + ab * t)).length)
            }
            return best
        }
    }

    static func residual(_ p: [V2], _ outline: [V2]) -> Double {
        let d = distances(p, to: outline)
        return d.reduce(0, +) / Double(d.count) / size(p)
    }

    /// Total least squares line: a point on it and its unit direction.
    static func tlsLine(_ p: [V2]) -> (V2, V2) {
        let n = Double(p.count)
        let c = p.reduce(V2(0, 0), +) / n
        var sxx = 0.0, sxy = 0.0, syy = 0.0
        for q in p {
            let d = q - c
            sxx += d.x * d.x; sxy += d.x * d.y; syy += d.y * d.y
        }
        // principal eigenvector of the 2x2 scatter matrix
        let theta = 0.5 * Double.atan2(y: 2 * sxy, x: sxx - syy)
        return (c, V2(Double.cos(theta), Double.sin(theta)))
    }

    static func intersect(_ c1: V2, _ d1: V2, _ c2: V2, _ d2: V2) -> V2? {
        let den = crossZ(d1, d2)
        if abs(den) < 0.17 { return nil }  // within ~10 degrees of parallel
        let t = crossZ(c2 - c1, d2) / den
        return c1 + d1 * t
    }

    static func closed(_ p: [V2]) -> [V2] { p.isEmpty ? p : p + [p[0]] }

    /// The convex hull by monotone chain, counter-clockwise in y-up terms. Points
    /// equal to 1e-6 count as one point, as in the Python implementation.
    static func convexHull(_ p: [V2]) -> [V2] {
        func r6(_ v: Double) -> Double { (v * 1e6).rounded(.toNearestOrEven) / 1e6 }
        var seen = Set<[Double]>()
        var pts: [V2] = []
        for q in p {
            let key = [r6(q.x), r6(q.y)]
            if seen.insert(key).inserted { pts.append(V2(key[0], key[1])) }
        }
        pts.sort { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        if pts.count < 3 { return pts }
        func half(_ seq: [V2]) -> [V2] {
            var h: [V2] = []
            for q in seq {
                while h.count >= 2 && crossZ(h[h.count - 1] - h[h.count - 2], q - h[h.count - 2]) <= 0 {
                    h.removeLast()
                }
                h.append(q)
            }
            return h
        }
        return Array(half(pts).dropLast()) + Array(half(pts.reversed()).dropLast())
    }

    static func polygonCentroid(_ poly: [V2]) -> V2 {
        var a = 0.0, cx = 0.0, cy = 0.0
        for i in 0..<poly.count {
            let p = poly[i], q = poly[(i + 1) % poly.count]
            let cr = p.x * q.y - q.x * p.y
            a += cr; cx += (p.x + q.x) * cr; cy += (p.y + q.y) * cr
        }
        a /= 2
        if abs(a) < 1e-12 { return poly.reduce(V2(0, 0), +) / Double(poly.count) }
        return V2(cx, cy) / (6 * a)
    }

    /// `n` points evenly spaced around a closed loop, from its first point.
    static func resampleClosed(_ loop: [V2], count n: Int) -> [V2] {
        let c = closed(loop)
        var s = [0.0]
        for i in 1..<c.count { s.append(s[i - 1] + (c[i] - c[i - 1]).length) }
        let total = s[s.count - 1]
        var out: [V2] = []
        var j = 0
        for i in 0..<n {
            let t = total * Double(i) / Double(n)
            while j < c.count - 2 && s[j + 1] < t { j += 1 }
            out.append(interp(t, s, c, j))
        }
        return out
    }

    /// `np.interp` over a polyline at arc length `t`, starting the search at `j`.
    private static func interp(_ t: Double, _ s: [Double], _ c: [V2], _ j: Int) -> V2 {
        var k = j
        while k < s.count - 2 && s[k + 1] <= t { k += 1 }
        let span = s[k + 1] - s[k]
        if span <= 0 { return c[k + 1] }
        let u = (t - s[k]) / span
        return c[k] + (c[k + 1] - c[k]) * u
    }

    /// The `k` largest values of a circular signal at least `minSep` apart,
    /// ascending by index, picked greedily from the largest down.
    static func circularPeaks(_ signal: [Double], k: Int, minSep: Int) -> [Int] {
        let m = signal.count
        let order = signal.indices.sorted { signal[$0] != signal[$1] ? signal[$0] > signal[$1] : $0 < $1 }
        var out: [Int] = []
        for i in order {
            if out.allSatisfy({ min(abs(i - $0), m - abs(i - $0)) >= minSep }) {
                out.append(i)
                if out.count == k { break }
            }
        }
        return out.sorted()
    }

    /// A box filter over a circular signal (`np.convolve(..., "same")` on the
    /// signal padded with `width` values from each end).
    static func smoothCircular(_ x: [Double], width w: Int) -> [Double] {
        guard w > 1 else { return x }
        let m = x.count
        let padded = Array(x[(m - w)...]) + x + Array(x[..<w])
        let half = (w - 1) / 2 + (w - 1) % 2  // where numpy centers an even kernel
        return (0..<m).map { i in
            let center = i + w
            var acc = 0.0
            for k in 0..<w {
                let idx = center - half + k
                if idx >= 0 && idx < padded.count { acc += padded[idx] }
            }
            return acc / Double(w)
        }
    }

    /// Linear-interpolated percentile (numpy's default).
    static func percentile(_ v: [Double], _ q: Double) -> Double {
        let s = v.sorted()
        let pos = q / 100 * Double(s.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, s.count - 1)
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }

    static func median(_ v: [Double]) -> Double { percentile(v, 50) }

    static func turning(_ p: [V2]) -> [Double] {
        // absolute turn at each vertex of a closed loop
        let m = p.count
        let e = (0..<m).map { p[($0 + 1) % m] - p[$0] }
        let a = e.map { Double.atan2(y: $0.y, x: $0.x) }
        return (0..<m).map { i in abs(wrap(a[i] - a[(i - 1 + m) % m])) }
    }

    static func wrap(_ x: Double) -> Double {
        // np.angle(np.exp(1j * x))
        Double.atan2(y: Double.sin(x), x: Double.cos(x))
    }

    static func shape(_ v: V2) -> Point { Point(x: v.x, y: v.y) }

    // MARK: - Connectors

    static func bezier(_ c: [V2], count n: Int) -> [V2] {
        (0..<n).map { Bezier.point(c[0], c[1], c[2], c[3], Double($0) / Double(n - 1)) }
    }

    /// Least-squares cubic with fixed end points, chord-length parameters
    /// refined by moving each point's parameter to its nearest point on the curve.
    static func cubic(_ p: [V2], iterations: Int = 3) -> [V2] {
        let p0 = p[0], p3 = p[p.count - 1]
        var cum = [0.0]
        for i in 1..<p.count { cum.append(cum[i - 1] + (p[i] - p[i - 1]).length) }
        let total = max(cum[cum.count - 1], 1e-12)
        var t = cum.map { $0 / total }
        var ctrl = [p0, p0 + (p3 - p0) / 3, p0 + (p3 - p0) * (2.0 / 3), p3]
        for _ in 0...iterations {
            var a11 = 0.0, a12 = 0.0, a22 = 0.0
            var r1 = V2(0, 0), r2 = V2(0, 0)
            for (i, q) in p.enumerated() {
                let u = 1 - t[i]
                let b0 = u * u * u, b1 = 3 * u * u * t[i], b2 = 3 * u * t[i] * t[i], b3 = t[i] * t[i] * t[i]
                let rhs = q - p0 * b0 - p3 * b3
                a11 += b1 * b1; a12 += b1 * b2; a22 += b2 * b2
                r1 = r1 + rhs * b1; r2 = r2 + rhs * b2
            }
            let det = a11 * a22 - a12 * a12
            if abs(det) > 1e-18 {
                ctrl = [p0, (r1 * a22 - r2 * a12) / det, (r2 * a11 - r1 * a12) / det, p3]
            }
            let dense = bezier(ctrl, count: 200)
            t = p.map { q in
                var best = 0, bd = Double.infinity
                for (j, d) in dense.enumerated() {
                    let e = (q - d).x * (q - d).x + (q - d).y * (q - d).y
                    if e < bd { bd = e; best = j }
                }
                return Double(best) / 199
            }
            t[0] = 0; t[t.count - 1] = 1
            for i in 1..<t.count { t[i] = max(t[i], t[i - 1]) }
        }
        return ctrl
    }

    static func connector(_ p: [V2], tolerance: Double) -> Fit {
        let (c, d) = tlsLine(p)
        let proj = p.map { dot($0 - c, d) }
        var a = c + d * (proj.min() ?? 0), b = c + d * (proj.max() ?? 0)
        if (a - p[0]).length > (b - p[0]).length { swap(&a, &b) }
        let length = max((b - a).length, 1e-9)
        let normal = V2(-d.y, d.x)
        let dev = (p.map { abs(dot($0 - c, normal)) }.max() ?? 0) / length
        if dev <= tolerance {
            let outline = [a, b]
            return Fit(shape: .line(from: shape(a), to: shape(b)), outline: outline, residual: residual(p, outline))
        }
        let ctrl = cubic(p)
        let outline = bezier(ctrl, count: 48)
        return Fit(shape: .curve(from: shape(ctrl[0]), control1: shape(ctrl[1]), control2: shape(ctrl[2]), to: shape(ctrl[3])),
                   outline: outline, residual: residual(p, outline))
    }

    /// The shaft is the longest run of points the model doesn't mark as
    /// arrowhead. Each end with two or more arrowhead points gets a head, and the
    /// tip moves to the head point furthest along the shaft's direction.
    static func arrow(_ p: [V2], head: [Float], tolerance: Double) -> Fit {
        let n = p.count
        let mask = (0..<n).map { $0 < head.count && head[$0] > 0.5 }
        var best = 0, run = 0, span = (0, n)
        for i in 0...n {
            if i < n && !mask[i] { run += 1; continue }
            if run > best { best = run; span = (i - run, i) }
            run = 0
        }
        var (s0, s1) = span
        if s1 - s0 < 4 { (s0, s1) = (0, n) }
        let shaftPoints = Array(p[s0..<s1])
        let shaft = connector(shaftPoints, tolerance: tolerance)
        let startHead = s0 > 1 && mask[..<s0].filter { $0 }.count >= 2
        var endHead = s1 < n - 1 && mask[s1...].filter { $0 }.count >= 2
        if !(startHead || endHead) { endHead = true }

        // the shaft as a cubic; for a straight shaft the controls are on the line
        var ctrl: [V2]
        switch shaft.shape {
        case let .curve(a, c1, c2, b):
            ctrl = [a, c1, c2, b].map { V2($0.x, $0.y) }
        case let .line(a, b):
            let va = V2(a.x, a.y), vb = V2(b.x, b.y)
            ctrl = [va, va + (vb - va) / 3, va + (vb - va) * (2.0 / 3), vb]
        default:
            ctrl = [p[0], p[0], p[n - 1], p[n - 1]]
        }
        var sp = shaft.outline
        let sz = size(p)
        for atEnd in [false, true] where atEnd ? endHead : startHead {
            let region = atEnd ? Array(p[(s1 - 1)...]) : Array(p[...s0])
            let tip = atEnd ? sp[sp.count - 1] : sp[0]
            let nb = atEnd ? sp[sp.count - min(4, sp.count)] : sp[min(3, sp.count - 1)]
            var dir = tip - nb
            dir = dir / max(dir.length, 1e-9)
            guard region.count > 1 else { continue }
            let reach = region.map { dot($0 - tip, dir) }.max() ?? 0
            if reach > 0 && reach < 0.25 * sz {
                let moved = tip + dir * reach
                if atEnd { sp[sp.count - 1] = moved; ctrl[3] = moved } else { sp[0] = moved; ctrl[0] = moved }
            }
        }
        if case .line = shaft.shape {
            ctrl = [ctrl[0], ctrl[0] + (ctrl[3] - ctrl[0]) / 3, ctrl[0] + (ctrl[3] - ctrl[0]) * (2.0 / 3), ctrl[3]]
        }
        return Fit(shape: .arrow(from: shape(ctrl[0]), control1: shape(ctrl[1]), control2: shape(ctrl[2]),
                                 to: shape(ctrl[3]), startHead: startHead, endHead: endHead),
                   outline: sp, residual: residual(shaftPoints, sp))
    }

    // MARK: - Ellipse

    static func ellipseOutline(_ c: V2, _ a: Double, _ b: Double, _ theta: Double, count n: Int = 96) -> [V2] {
        let ct = Double.cos(theta), st = Double.sin(theta)
        return (0...n).map { i in
            let t = 2 * Double.pi * Double(i) / Double(n)
            let x = a * Double.cos(t), y = b * Double.sin(t)
            return V2(c.x + x * ct - y * st, c.y + x * st + y * ct)
        }
    }

    /// Direct least-squares ellipse (Halir and Flusser), falling back to second
    /// moments when the conic is not an ellipse.
    static func ellipse(_ p: [V2]) -> Fit {
        let n = Double(p.count)
        let mu = p.reduce(V2(0, 0), +) / n
        let sc = size(p)
        let q = p.map { ($0 - mu) / sc }
        var s1 = [[Double]](repeating: [0, 0, 0], count: 3)
        var s2 = s1, s3 = s1
        for v in q {
            let d1 = [v.x * v.x, v.x * v.y, v.y * v.y], d2 = [v.x, v.y, 1.0]
            for i in 0..<3 { for j in 0..<3 {
                s1[i][j] += d1[i] * d1[j]; s2[i][j] += d1[i] * d2[j]; s3[i][j] += d2[i] * d2[j]
            } }
        }
        var center = mu, a = 0.0, b = 0.0, theta = 0.0, ok = false
        if let s3inv = Mat3.inverse(s3) {
            // T = -S3^-1 S2^T, M = S1 + S2 T, then the constraint matrix applied
            let t = Mat3.mul(Mat3.scale(s3inv, -1), Mat3.transpose(s2))
            let m = Mat3.add(s1, Mat3.mul(s2, t))
            let mc = [m[2].map { $0 / 2 }, m[1].map { -$0 }, m[0].map { $0 / 2 }]
            for v in Mat3.realEigenvectors(mc) where 4 * v[0] * v[2] - v[1] * v[1] > 0 {
                let A = v[0], B = v[1], C = v[2]
                let def = Mat3.mulVec(t, v)
                let D = def[0], E = def[1], F = def[2]
                let den = B * B - 4 * A * C
                let cx = (2 * C * D - B * E) / den, cy = (2 * A * E - B * D) / den
                let num = 2 * (A * E * E + C * D * D - B * D * E + den * F)
                let root = ((A - C) * (A - C) + B * B).squareRoot()
                let ra = -max(num * (A + C + root), 0).squareRoot() / den
                let rb = -max(num * (A + C - root), 0).squareRoot() / den
                theta = (B != 0 || A > C) ? 0.5 * Double.atan2(y: -B, x: C - A) : 0
                if A > C && B == 0 { theta = Double.pi / 2 }
                if ra > 0 && rb > 0 && (ra + rb).isFinite {
                    center = V2(cx, cy) * sc + mu
                    a = ra * sc; b = rb * sc
                    ok = true
                }
                break
            }
        }
        if !ok || max(a, b) > 3 * sc {
            var sxx = 0.0, sxy = 0.0, syy = 0.0
            for v in p { let d = v - mu; sxx += d.x * d.x; sxy += d.x * d.y; syy += d.y * d.y }
            let k = n - 1
            sxx /= k; sxy /= k; syy /= k
            let tr = sxx + syy, det = sxx * syy - sxy * sxy
            let disc = max(tr * tr / 4 - det, 0).squareRoot()
            let l1 = tr / 2 + disc, l2 = tr / 2 - disc
            center = mu
            a = (2 * max(l1, 1e-12)).squareRoot(); b = (2 * max(l2, 1e-12)).squareRoot()
            theta = 0.5 * Double.atan2(y: 2 * sxy, x: sxx - syy)
        }
        if b > a { swap(&a, &b); theta += Double.pi / 2 }
        theta = (theta + Double.pi / 2).truncatingRemainder(dividingBy: Double.pi)
        if theta < 0 { theta += Double.pi }
        theta -= Double.pi / 2
        let outline = ellipseOutline(center, a, b, theta)
        return Fit(shape: .ellipse(center: shape(center), semiMajor: a, semiMinor: b, rotation: theta),
                   outline: outline, residual: residual(p, outline))
    }

    // MARK: - Polygons

    /// An oriented rectangle: orientation from the tangents' four-fold mean,
    /// then each side at the median of the points nearest it, iterated.
    static func rectangle(_ p: [V2]) -> Fit {
        var sx = 0.0, sy = 0.0
        for i in 0..<(p.count - 1) {
            let d = p[i + 1] - p[i], w = d.length, phi = Double.atan2(y: d.y, x: d.x)
            sx += w * Double.sin(4 * phi); sy += w * Double.cos(4 * phi)
        }
        let theta = 0.25 * Double.atan2(y: sx, x: sy)
        let c = Double.cos(theta), s = Double.sin(theta)
        let q = p.map { V2(c * $0.x + s * $0.y, -s * $0.x + c * $0.y) }
        var e = [percentile(q.map(\.x), 3), percentile(q.map(\.x), 97),
                 percentile(q.map(\.y), 3), percentile(q.map(\.y), 97)]  // x0, x1, y0, y1
        for _ in 0..<3 {
            let side = q.map { v -> Int in
                let dist = [abs(v.x - e[0]), abs(v.x - e[1]), abs(v.y - e[2]), abs(v.y - e[3])]
                return dist.indices.min { dist[$0] < dist[$1] || (dist[$0] == dist[$1] && $0 < $1) }!
            }
            var next = e
            for k in 0..<4 {
                let vals = q.indices.filter { side[$0] == k }.map { k < 2 ? q[$0].x : q[$0].y }
                if vals.count >= 3 { next[k] = median(vals) }
            }
            e = next
        }
        let local = [V2(e[0], e[2]), V2(e[1], e[2]), V2(e[1], e[3]), V2(e[0], e[3])]
        let corners = local.map { V2(c * $0.x - s * $0.y, s * $0.x + c * $0.y) }
        let outline = closed(corners)
        return Fit(shape: .rectangle(corners: corners.map(shape)), outline: outline, residual: residual(p, outline))
    }

    /// A convex k-gon: corners where the convex hull turns most, then each side
    /// refit through the stroke points nearest it and adjacent sides intersected.
    static func convexPolygon(_ p: [V2], k: Int, kind: Shape.Kind, refine: Bool = true) -> Fit {
        func make(_ v: [V2]) -> Shape {
            let pts = v.map(shape)
            switch kind {
            case .triangle: return .triangle(vertices: pts)
            case .diamond: return .diamond(vertices: pts)
            case .pentagon: return .pentagon(vertices: pts)
            default: return .hexagon(vertices: pts)
            }
        }
        let hull = convexHull(p)
        if hull.count < 3 { return Fit(shape: make(Array(p.prefix(k))), outline: p, residual: 1) }
        let m = 180
        let h = resampleClosed(hull, count: m)
        let turn = smoothCircular(turning(h), width: 5)
        let corners = circularPeaks(turn, k: k, minSep: max(2, m / (3 * k)))
        var verts = corners.map { h[$0] }
        if verts.count < k { return Fit(shape: make(verts), outline: closed(verts), residual: 1) }
        let sz = size(p)
        for _ in 0..<(refine ? 2 : 0) {
            let poly = closed(verts)
            let side = p.map { q -> Int in
                let d = (0..<k).map { distances([q], to: [poly[$0], poly[$0 + 1]])[0] }
                return d.indices.min { d[$0] < d[$1] || (d[$0] == d[$1] && $0 < $1) }!
            }
            var lines: [(V2, V2)] = []
            for i in 0..<k {
                var pts = p.indices.filter { side[$0] == i }.map { p[$0] }
                let a = poly[i], b = poly[i + 1]
                if pts.count >= 3 {
                    let ab = b - a, l2 = max(dot(ab, ab), 1e-12)
                    let kept = pts.filter { let t = dot($0 - a, ab) / l2; return t > 0.12 && t < 0.88 }
                    if kept.count >= 3 { pts = kept }
                    lines.append(tlsLine(pts))
                } else {
                    let d = b - a
                    lines.append(((a + b) / 2, d / max(d.length, 1e-12)))
                }
            }
            verts = (0..<k).map { i in
                let prev = lines[(i - 1 + k) % k], cur = lines[i]
                if let x = intersect(prev.0, prev.1, cur.0, cur.1), (x - verts[i]).length <= 0.5 * sz { return x }
                return verts[i]
            }
        }
        let outline = closed(verts)
        return Fit(shape: make(verts), outline: outline, residual: residual(p, outline))
    }

    // MARK: - Star

    static func starOutline(_ c: V2, _ rOut: Double, _ rIn: Double, _ rot: Double, _ k: Int) -> [V2] {
        closed((0..<(2 * k)).map { i in
            let a = rot + Double.pi * Double(i) / Double(k)
            let r = i % 2 == 0 ? rOut : rIn
            return V2(c.x + r * Double.cos(a), c.y + r * Double.sin(a))
        })
    }

    /// The fitter's `rot` is the angle of a tip. `Shape.star` puts a tip
    /// straight up at rotation 0, in [0, 2 pi / k).
    static func starShape(_ c: V2, _ rOut: Double, _ rIn: Double, _ rot: Double, _ k: Int) -> Shape {
        let period = 2 * Double.pi / Double(k)
        var r = (rot + Double.pi / 2).truncatingRemainder(dividingBy: period)
        if r < 0 { r += period }
        return .star(center: shape(c), outerRadius: rOut, innerRadius: rIn, rotation: r, pointCount: k)
    }

    static func densify(_ p: [V2]) -> [V2] {
        var out: [V2] = []
        for i in 0..<(p.count - 1) { for j in 0..<8 { out.append(p[i] + (p[i + 1] - p[i]) * (Double(j) / 8)) } }
        out.append(p[p.count - 1])
        return out
    }

    static func starEnvelope(_ p: [V2]) -> Fit? {
        let hull = convexHull(p)
        let center = hull.count >= 3 ? polygonCentroid(hull) : p.reduce(V2(0, 0), +) / Double(p.count)
        let dense = densify(p)
        let bins = 180
        var env = [Double](repeating: 0, count: bins)
        for q in dense {
            let v = q - center
            let ang = Double.atan2(y: v.y, x: v.x)
            var b = Int((ang + Double.pi) / (2 * Double.pi) * Double(bins))
            b = ((b % bins) + bins) % bins
            env[b] = max(env[b], v.length)
        }
        for _ in 0..<bins {
            let zero = env.indices.filter { env[$0] == 0 }
            if zero.isEmpty { break }
            let snapshot = env
            for i in zero { env[i] = max(snapshot[(i - 1 + bins) % bins], snapshot[(i + 1) % bins]) }
        }
        let sm = smoothCircular(env, width: 3)
        var best: Fit?
        for k in [5, 6] {
            let tips = circularPeaks(sm, k: k, minSep: bins / (2 * k))
            if tips.count < k { continue }
            let rOut = tips.map { env[$0] }.reduce(0, +) / Double(k)
            var cs = 0.0, ss = 0.0
            for t in tips {
                let a = (Double(t) + 0.5) / Double(bins) * 2 * Double.pi - Double.pi
                cs += Double.cos(Double(k) * a); ss += Double.sin(Double(k) * a)
            }
            let rot = Double.atan2(y: ss / Double(k), x: cs / Double(k)) / Double(k)
            var valleys: [Double] = []
            for i in 0..<k {
                let a = tips[i], b = tips[(i + 1) % k]
                let seg = b > a ? Array(sm[a..<b]) : Array(sm[a...]) + Array(sm[..<b])
                valleys.append(seg.min() ?? rOut * 0.4)
            }
            let rIn = min(max(median(valleys), 0.15 * rOut), 0.8 * rOut)
            let outline = starOutline(center, rOut, rIn, rot, k)
            let f = Fit(shape: starShape(center, rOut, rIn, rot, k), outline: outline, residual: residual(p, outline))
            if best == nil || f.residual < best!.residual * 0.85 { best = f }
        }
        return best
    }

    static func starHull(_ p: [V2]) -> Fit? {
        let dense = densify(p)
        var best: Fit?
        for k in [5, 6] {
            let hf = convexPolygon(p, k: k, kind: .hexagon, refine: false)
            let tips = Array(hf.outline.dropLast())
            if tips.count < k { continue }
            let center = tips.reduce(V2(0, 0), +) / Double(k)
            let rOut = tips.map { ($0 - center).length }.reduce(0, +) / Double(k)
            var cs = 0.0, ss = 0.0
            for t in tips {
                let a = Double.atan2(y: t.y - center.y, x: t.x - center.x)
                cs += Double.cos(Double(k) * a); ss += Double.sin(Double(k) * a)
            }
            let rot = Double.atan2(y: ss / Double(k), x: cs / Double(k)) / Double(k)
            var valleys: [Double] = []
            for i in 0..<k {
                let mid = rot + Double(2 * i + 1) * Double.pi / Double(k)
                let near = dense.filter { q in
                    abs(wrap(Double.atan2(y: q.y - center.y, x: q.x - center.x) - mid)) < Double.pi / Double(3 * k)
                }
                if let m = near.map({ ($0 - center).length }).max() { valleys.append(m) }
            }
            let rIn = min(max(valleys.isEmpty ? 0.4 * rOut : median(valleys), 0.15 * rOut), 0.8 * rOut)
            let outline = starOutline(center, rOut, rIn, rot, k)
            let f = Fit(shape: starShape(center, rOut, rIn, rot, k), outline: outline, residual: residual(p, outline))
            if best == nil || f.residual < best!.residual * 0.85 { best = f }
        }
        return best
    }

    /// The better (lower residual) of the envelope and hull fits.
    static func star(_ p: [V2]) -> Fit {
        let fits = [starEnvelope(p), starHull(p)].compactMap { $0 }
        if let best = fits.min(by: { $0.residual < $1.residual }) { return best }
        let hull = convexHull(p)
        return Fit(shape: starShape(p.reduce(V2(0, 0), +) / Double(p.count), 1, 0.4, 0, 5),
                   outline: closed(hull), residual: 1)
    }

    // MARK: - Heart, cloud, scribble

    static func heart(_ p: [V2]) -> Fit {
        let lo = V2(percentile(p.map(\.x), 1), percentile(p.map(\.y), 1))
        let hi = V2(percentile(p.map(\.x), 99), percentile(p.map(\.y), 99))
        let center = (lo + hi) / 2, box = hi - lo
        let outline = Templates.heart(center: center, width: box.x, height: box.y, count: 96, closed: true)
        return Fit(shape: .heart(center: shape(center), width: box.x, height: box.y),
                   outline: outline, residual: residual(p, outline))
    }

    /// Cuts a closed stroke's overlap where its cumulative turning completes a turn.
    static func oneLap(_ p: [V2]) -> [V2] {
        let a = (0..<(p.count - 1)).map { Double.atan2(y: p[$0 + 1].y - p[$0].y, x: p[$0 + 1].x - p[$0].x) }
        var cum = 0.0
        for i in 0..<(a.count - 1) {
            cum += wrap(a[i + 1] - a[i])
            if abs(cum) >= 2 * Double.pi { return Array(p[..<(i + 2)]) }
        }
        return p
    }

    static func circle3(_ a: V2, _ b: V2, _ c: V2) -> (V2, Double)? {
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        if abs(d) < 1e-12 { return nil }
        let aa = dot(a, a), bb = dot(b, b), cc = dot(c, c)
        let o = V2((aa * (b.y - c.y) + bb * (c.y - a.y) + cc * (a.y - b.y)) / d,
                   (aa * (c.x - b.x) + bb * (a.x - c.x) + cc * (b.x - a.x)) / d)
        return (o, (a - o).length)
    }

    /// The circular arc a -> m -> b, `n` samples (a polyline when collinear).
    static func arc3(_ a: V2, _ m: V2, _ b: V2, count n: Int = 16) -> [V2] {
        guard let (o, r) = circle3(a, m, b) else { return [a, m, b] }
        let t0 = Double.atan2(y: a.y - o.y, x: a.x - o.x)
        let tm = Double.atan2(y: m.y - o.y, x: m.x - o.x)
        let t1 = Double.atan2(y: b.y - o.y, x: b.x - o.x)
        func mod(_ x: Double) -> Double { let y = x.truncatingRemainder(dividingBy: 2 * Double.pi); return y < 0 ? y + 2 * Double.pi : y }
        var span = mod(t1 - t0)
        if mod(tm - t0) > span { span -= 2 * Double.pi }
        return (0..<n).map { i in
            let t = t0 + span * Double(i) / Double(n - 1)
            return V2(o.x + r * Double.cos(t), o.y + r * Double.sin(t))
        }
    }

    /// The cloud as drawn: one lap of the stroke, split at the concave cusps
    /// between bumps, with each bump replaced by the circular arc through its
    /// two cusps and its outermost point.
    static func cloudArcs(_ p: [V2]) -> Fit {
        let lap = resampleClosed(oneLap(p), count: 192)
        let m = lap.count
        let e = (0..<m).map { lap[($0 + 1) % m] - lap[$0] }
        let ang = e.map { Double.atan2(y: $0.y, x: $0.x) }
        let turn = (0..<m).map { wrap(ang[$0] - ang[($0 - 1 + m) % m]) }
        // The winding comes from the signed area. On a cloud with loops the
        // turning sum is close to 0, and its sign would be rounding noise.
        var area = 0.0
        for i in 0..<m { area += lap[i].x * lap[(i + 1) % m].y - lap[i].y * lap[(i + 1) % m].x }
        let orient: Double = area >= 0 ? 1 : -1
        let concave = smoothCircular(turn.map { max(-orient * $0, 0) }, width: 3)
        let cusps = circularPeaks(concave, k: 24, minSep: 6).filter { concave[$0] > 0.12 }
        if cusps.count < 3 {
            let ef = ellipse(p)
            return Fit(shape: .cloud(outline: ef.outline.dropLast().map(shape)), outline: ef.outline, residual: ef.residual)
        }
        var pts: [V2] = []
        for j in 0..<cusps.count {
            let i0 = cusps[j], i1 = cusps[(j + 1) % cusps.count]
            let idx = (i0..<(i1 > i0 ? i1 : i1 + m)).map { $0 % m }
            let seg = idx.map { lap[$0] }
            let a = lap[i0], b = lap[i1]
            let chord = b - a
            let normal = V2(-chord.y, chord.x) / max(chord.length, 1e-9)
            let dev = seg.map { abs(dot($0 - a, normal)) }
            let devMax = dev.max() ?? 0
            if devMax < 0.06 * chord.length {
                pts.append(a)  // a flat stretch, such as a cloud's base, stays straight
                continue
            }
            let far = seg[dev.firstIndex(of: devMax)!]
            pts.append(contentsOf: arc3(a, far, b).dropLast())
        }
        let outline = closed(pts)
        return Fit(shape: .cloud(outline: pts.map(shape)), outline: outline, residual: residual(p, outline))
    }

    /// The ellipse under the cloud and its bump count, drawn as a regular scallop.
    static func cloudScallop(_ p: [V2]) -> Fit {
        let ef = ellipse(p)
        guard case let .ellipse(cp, a, b, th) = ef.shape else { return ef }
        let c = V2(cp.x, cp.y), ct = Double.cos(th), st = Double.sin(th)
        let r = p.map { q -> Double in
            let v = q - c
            return V2((v.x * ct + v.y * st) / a, (-v.x * st + v.y * ct) / b).length
        }
        let mean = r.reduce(0, +) / Double(r.count)
        let d = r.map { $0 - mean }
        // np.convolve(d, ones(3)/3, "same"), zero-padded
        let rs = d.indices.map { i in
            ((i > 0 ? d[i - 1] : 0) + d[i] + (i < d.count - 1 ? d[i + 1] : 0)) / 3
        }
        var peaks = 0
        for i in 1..<(rs.count - 1) where rs[i] > rs[i - 1] && rs[i] >= rs[i + 1] && rs[i] > 0.02 { peaks += 1 }
        let bumps = min(max(peaks, 4), 16)
        let n = bumps * 16
        let outline: [V2] = (0...n).map { i in
            let t = 2 * Double.pi * Double(i) / Double(n)
            let scallop = 1 + 0.12 * abs(Double.sin(t * Double(bumps) / 2))
            let x = a * scallop * Double.cos(t) * 0.9, y = b * scallop * Double.sin(t) * 0.9
            return V2(c.x + x * ct - y * st, c.y + x * st + y * ct)
        }
        return Fit(shape: .cloud(outline: outline.dropLast().map(shape)), outline: outline, residual: residual(p, outline))
    }

    static func cloud(_ p: [V2]) -> Fit {
        let a = cloudArcs(p), s = cloudScallop(p)
        return a.residual <= s.residual ? a : s
    }

    static func scribble(_ p: [V2]) -> Fit {
        let hull = convexHull(p)
        let outline = hull.count >= 3 ? closed(hull) : p
        return Fit(shape: .scribble(hull: (hull.count >= 3 ? hull : p).map(shape)), outline: outline, residual: 0)
    }
}

/// The 3x3 linear algebra the ellipse fit needs, on row-major arrays.
enum Mat3 {
    typealias M = [[Double]]

    static func mul(_ a: M, _ b: M) -> M {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + a[i][$1] * b[$1][j] } } }
    }
    static func mulVec(_ a: M, _ v: [Double]) -> [Double] {
        (0..<3).map { i in (0..<3).reduce(0) { $0 + a[i][$1] * v[$1] } }
    }
    static func add(_ a: M, _ b: M) -> M { (0..<3).map { i in (0..<3).map { a[i][$0] + b[i][$0] } } }
    static func scale(_ a: M, _ s: Double) -> M { a.map { $0.map { $0 * s } } }
    static func transpose(_ a: M) -> M { (0..<3).map { i in (0..<3).map { a[$0][i] } } }

    static func inverse(_ a: M) -> M? {
        let det = a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
            - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
            + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        guard abs(det) > 1e-300 else { return nil }
        let c: M = [
            [a[1][1] * a[2][2] - a[1][2] * a[2][1], a[0][2] * a[2][1] - a[0][1] * a[2][2], a[0][1] * a[1][2] - a[0][2] * a[1][1]],
            [a[1][2] * a[2][0] - a[1][0] * a[2][2], a[0][0] * a[2][2] - a[0][2] * a[2][0], a[0][2] * a[1][0] - a[0][0] * a[1][2]],
            [a[1][0] * a[2][1] - a[1][1] * a[2][0], a[0][1] * a[2][0] - a[0][0] * a[2][1], a[0][0] * a[1][1] - a[0][1] * a[1][0]],
        ]
        return scale(c, 1 / det)
    }

    /// Eigenvectors of a real 3x3 matrix for its real eigenvalues (roots of
    /// the characteristic cubic), each the null vector of `A - lambda I`.
    static func realEigenvectors(_ a: M) -> [[Double]] {
        // det(A - l I) = -l^3 + tr l^2 - c2 l + det
        let tr = a[0][0] + a[1][1] + a[2][2]
        let c2 = a[0][0] * a[1][1] - a[0][1] * a[1][0] + a[0][0] * a[2][2] - a[0][2] * a[2][0]
            + a[1][1] * a[2][2] - a[1][2] * a[2][1]
        let det = a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1])
            - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
            + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        var vectors: [[Double]] = []
        for l in cubicRoots(1, -tr, c2, -det) {
            let b = (0..<3).map { i in (0..<3).map { a[i][$0] - (i == $0 ? l : 0) } }
            // the null vector is the largest cross product of two rows
            let pairs = [(0, 1), (0, 2), (1, 2)]
            var best: [Double] = [0, 0, 0], bestNorm = 0.0
            for (i, j) in pairs {
                let r = b[i], s = b[j]
                let v = [r[1] * s[2] - r[2] * s[1], r[2] * s[0] - r[0] * s[2], r[0] * s[1] - r[1] * s[0]]
                let norm = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot()
                if norm > bestNorm { best = v; bestNorm = norm }
            }
            if bestNorm > 0 { vectors.append(best.map { $0 / bestNorm }) }
        }
        return vectors
    }

    /// Real roots of x^3 + b x^2 + c x + d (leading 1), polished by Newton.
    static func cubicRoots(_ a0: Double, _ b0: Double, _ c0: Double, _ d0: Double) -> [Double] {
        let b = b0 / a0, c = c0 / a0, d = d0 / a0
        let p = c - b * b / 3, q = 2 * b * b * b / 27 - b * c / 3 + d
        let disc = q * q / 4 + p * p * p / 27
        var roots: [Double]
        if disc > 0 {
            let s = disc.squareRoot()
            roots = [Double.root(-q / 2 + s, 3) + Double.root(-q / 2 - s, 3)]
        } else {
            let r = (-p / 3).squareRoot()
            let phi = Double.acos(max(-1, min(1, -q / (2 * r * r * r + 1e-300))))
            roots = (0..<3).map { k in 2 * r * Double.cos((phi + 2 * Double.pi * Double(k)) / 3) }
        }
        return roots.map { y in
            var x = y - b / 3
            for _ in 0..<3 {
                let f = ((x + b) * x + c) * x + d, df = (3 * x + 2 * b) * x + c
                if df != 0 { x -= f / df }
            }
            return x
        }
    }
}
