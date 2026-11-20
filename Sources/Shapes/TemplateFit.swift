import RealModule

/// The template fit: a kind's template numbers moved so its clean outline lies
/// on the ink, starting from the model's numbers. It works the same way for
/// every kind and for a drawing of several strokes. The outlines and the loss
/// match the Python implementation (`templates.parts` and `fit._descend` in
/// ml-shapes); the gradient here comes from central differences instead of
/// autograd.
enum TemplateFit {
    /// Steps of the descent. From the model's numbers, 40 steps land where the
    /// Python fitter's 160 from its own starts do (ml-shapes probe fit_from_model).
    static let steps = 40
    /// Adam's starting learning rate, cosine-decayed to zero.
    static let learningRate = 0.02
    /// Outline points per side while fitting, and for the residual.
    static let fitSide = 12
    static let residualSide = 16
    /// Weight of the outline-to-ink term in the loss.
    static let cover = 0.3
    /// Points the drawing is resampled to for the fit, as the residual's.
    static let pointCount = 128

    struct Fit {
        /// The fitted numbers in the drawing's frame, canonical.
        let numbers: [Double]
        /// The SDK residual: mean distance from the points to the outline, over
        /// the points' larger side.
        let residual: Double
    }

    /// Fit `kind` to `points` (the drawing in its frame) from `start`.
    static func fit(_ kind: String, points: [V2], from start: [Double]) -> Fit {
        // a zigzag's teeth are a count: held, not descended
        let free = kind == "zigzag" ? start.count - 1 : start.count
        var p = start
        var m = [Double](repeating: 0, count: free), v = m
        let b1 = 0.9, b2 = 0.999, eps = 1e-8, h = 1e-4
        for i in 0..<steps {
            let lr = learningRate * 0.5 * (1 + Double.cos(Double.pi * Double(i) / Double(steps)))
            var g = [Double](repeating: 0, count: free)
            for j in 0..<free {
                var up = p, down = p
                up[j] += h
                down[j] -= h
                g[j] = (loss(kind, up, points) - loss(kind, down, points)) / (2 * h)
            }
            let t = Double(i + 1)
            for j in 0..<free {
                m[j] = b1 * m[j] + (1 - b1) * g[j]
                v[j] = b2 * v[j] + (1 - b2) * g[j] * g[j]
                let mh = m[j] / (1 - Double.pow(b1, t)), vh = v[j] / (1 - Double.pow(b2, t))
                p[j] -= lr * mh / (vh.squareRoot() + eps)
            }
        }
        return Fit(numbers: Numbers.canonical(kind, p), residual: residual(kind, p, points))
    }

    /// Mean distance from the points to the outline, plus `cover` times the mean
    /// distance from the outline's points to the nearest point.
    static func loss(_ kind: String, _ p: [Double], _ pts: [V2]) -> Double {
        let polys = parts(kind, p, n: fitSide)
        let toOutline = pts.reduce(0.0) { sum, q in sum + polys.map { distance(q, to: $0) }.min()! } / Double(pts.count)
        var toInk = 0.0, count = 0
        for poly in polys {
            for q in poly {
                var best = Double.infinity
                for r in pts { best = min(best, (q - r).length) }
                toInk += best
                count += 1
            }
        }
        return toOutline + cover * toInk / Double(max(count, 1))
    }

    /// The SDK residual of `kind` drawn from `p` against the points.
    static func residual(_ kind: String, _ p: [Double], _ pts: [V2]) -> Double {
        let polys = parts(kind, p, n: residualSide)
        let mean = pts.reduce(0.0) { sum, q in sum + polys.map { distance(q, to: $0) }.min()! } / Double(pts.count)
        var lo = pts[0], hi = pts[0]
        for q in pts { lo = vmin(lo, q); hi = vmax(hi, q) }
        return mean / max(hi.x - lo.x, hi.y - lo.y, 1e-9)
    }

    /// Distance from a point to a polyline.
    static func distance(_ q: V2, to poly: [V2]) -> Double {
        var best = Double.infinity
        for i in 0..<(poly.count - 1) {
            let a = poly[i], ab = poly[i + 1] - a
            let t = min(max(dot(q - a, ab) / max(dot(ab, ab), 1e-12), 0), 1)
            let d = q - (a + ab * t)
            best = min(best, (dot(d, d) + 1e-12).squareRoot())
        }
        return best
    }

    // MARK: Outlines

    /// The clean outline of a kind's template as polylines; a closed outline
    /// repeats its first point at the end. `n` is the points per side, per
    /// curve quarter or per segment.
    static func parts(_ kind: String, _ p: [Double], n: Int) -> [[V2]] {
        switch kind {
        case "line":
            return [cubic(Array(p[0..<8]), 4 * n)]
        case "arrow":
            let shaft = cubic(Array(p[0..<8]), 4 * n)
            return [shaft, arrowhead(tip: shaft[shaft.count - 1], back: shaft[shaft.count - max(2, n / 2)], head: p[8], n)]
        case "rectangle", "scribble":
            return [polyline(place([-0.5, 0.5, 0.5, -0.5], [-0.5, -0.5, 0.5, 0.5], p), closed: true, n)]
        case "ellipse":
            let ts = linspace(0, 2 * Double.pi, 4 * n + 1)
            return [ts.map { rot(V2(p[2] * Double.cos($0), p[3] * Double.sin($0)), p[4]) + V2(p[0], p[1]) }]
        case "triangle", "diamond", "pentagon", "hexagon":
            return [polyline(vertices(p), closed: true, n)]
        case "star":
            let inner = p[3] / max(p[2], 1e-6)
            let vs = (0..<10).map { i -> V2 in
                let a = -Double.pi / 2 + Double.pi * Double(i) / 5
                let r = i % 2 == 0 ? 1.0 : inner
                return V2(r * Double.cos(a), r * Double.sin(a))
            }
            var line = polyline(vs, closed: true, n / 2).map { rot($0 * p[2], p[4]) + V2(p[0], p[1]) }
            line.append(line[0])
            return [line]
        case "heart":
            let ts = linspace(0, 2 * Double.pi, 4 * n + 1)
            let u = ts.map { 16 * Double.pow(Double.sin($0), 3) / 32 }
            let v = ts.map { t -> Double in
                let hy = -(13 * Double.cos(t) - 5 * Double.cos(2 * t) - 2 * Double.cos(3 * t) - Double.cos(4 * t))
                return (hy - 2.5) / 29
            }
            return [place(u, v, p)]
        case "cloud":
            let ts = linspace(0, 2 * Double.pi, 8 * n + 1)
            let r = ts.map { 0.82 + 0.18 * abs(Double.sin(3.5 * $0)) }
            return [place(zip(ts, r).map { 0.5 * $1 * Double.cos($0) }, zip(ts, r).map { 0.5 * $1 * Double.sin($0) }, p)]
        case "check", "bracket":
            return [polyline(vertices(p), closed: false, n)]
        case "cross", "plus":
            let q = vertices(p)
            return [segment(q[0], q[1], 2 * n), segment(q[2], q[3], 2 * n)]
        case "zigzag":
            let vs = Templates.zigzag(from: V2(p[0], p[1]), to: V2(p[2], p[3]), amplitude: p[4], teeth: p[5])
            return [polyline(vs, closed: false, n / 2)]
        default:
            return []
        }
    }

    private static func vertices(_ p: [Double]) -> [V2] {
        stride(from: 0, to: p.count - 1, by: 2).map { V2(p[$0], p[$0 + 1]) }
    }

    private static func rot(_ q: V2, _ a: Double) -> V2 {
        let c = Double.cos(a), s = Double.sin(a)
        return V2(q.x * c - q.y * s, q.x * s + q.y * c)
    }

    /// A unit outline scaled by (w, h), turned by the angle and moved to the
    /// center: `p` = (cx, cy, w, h, angle).
    private static func place(_ u: [Double], _ v: [Double], _ p: [Double]) -> [V2] {
        zip(u, v).map { rot(V2($0 * p[2], $1 * p[3]), p[4]) + V2(p[0], p[1]) }
    }

    private static func linspace(_ a: Double, _ b: Double, _ n: Int) -> [Double] {
        (0..<n).map { n > 1 ? a + (b - a) * Double($0) / Double(n - 1) : a }
    }

    private static func segment(_ a: V2, _ b: V2, _ n: Int) -> [V2] {
        linspace(0, 1, n).map { a + (b - a) * $0 }
    }

    private static func polyline(_ vs: [V2], closed: Bool, _ n: Int) -> [V2] {
        let k = vs.count
        return (0..<(closed ? k : k - 1)).flatMap { segment(vs[$0], vs[($0 + 1) % k], n) }
    }

    private static func cubic(_ c: [Double], _ n: Int) -> [V2] {
        let p0 = V2(c[0], c[1]), p1 = V2(c[2], c[3]), p2 = V2(c[4], c[5]), p3 = V2(c[6], c[7])
        return linspace(0, 1, n).map { Bezier.point(p0, p1, p2, p3, $0) }
    }

    /// The two barbs as one polyline: barb end, tip, barb end.
    private static func arrowhead(tip: V2, back: V2, head: Double, _ n: Int) -> [V2] {
        let d = tip - back
        let a = Double.atan2(y: d.y, x: d.x), spread = 28 * Double.pi / 180
        let left = tip - V2(Double.cos(a - spread), Double.sin(a - spread)) * head
        let right = tip - V2(Double.cos(a + spread), Double.sin(a + spread)) * head
        return segment(left, tip, n) + segment(tip, right, n)
    }
}
