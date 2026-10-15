/// The model's input: the stroke resampled to `count` points evenly spaced by
/// arc length, keeping the first and last point, then moved so its bounding
/// box is centered on the origin and scaled so its longer side is 1.
///
/// The SDK normalizes before the graph because fp16 resolves canvas
/// coordinates in the thousands to a pixel or worse. The graph computes every
/// other feature itself. The code matches the Python implementation the model
/// was trained with, and `Tests/Fixtures/shapes-parity.json` holds that
/// implementation's outputs.
enum Preprocess {
    /// `count` points evenly spaced along the polyline, in its own units.
    /// Zero-length segments carry no arc length; a stroke with no length
    /// repeats its first point.
    static func resample(_ points: [Point], count n: Int) -> [V2] {
        guard let first = points.first else { return [] }
        if points.count == 1 { return Array(repeating: V2(first.x, first.y), count: n) }
        let p = points.map { V2($0.x, $0.y) }
        var cum = [0.0]
        cum.reserveCapacity(p.count)
        var seg = [Double]()
        seg.reserveCapacity(p.count - 1)
        for i in 1..<p.count {
            let d = (p[i] - p[i - 1]).length
            seg.append(d)
            cum.append(cum[i - 1] + d)
        }
        let total = cum[cum.count - 1]
        if !(total > 0) { return Array(repeating: p[0], count: n) }
        var out = [V2]()
        out.reserveCapacity(n)
        var idx = 0
        for j in 0..<n {
            let target = total * Double(j) / Double(n - 1)
            // `searchsorted(cum, target, side: right) - 1`, clipped to a segment
            while idx + 1 < cum.count && cum[idx + 1] <= target { idx += 1 }
            let i = min(idx, p.count - 2)
            let t = min(max((target - cum[i]) / max(seg[i], 1e-12), 0), 1)
            out.append(p[i] + (p[i + 1] - p[i]) * t)
        }
        return out
    }

    /// Moves the bounding box's center to the origin and scales the longer side to 1.
    static func normalize(_ p: [V2]) -> [V2] {
        guard let first = p.first else { return [] }
        var lo = first, hi = first
        for q in p { lo = vmin(lo, q); hi = vmax(hi, q) }
        let c = (lo + hi) / 2
        let scale = max(hi.x - lo.x, hi.y - lo.y, 1e-9)
        return p.map { ($0 - c) / scale }
    }

    /// The resampled stroke rounded through `Float`. The Python resampler
    /// returns float32, so the fitter and the model input get the same points
    /// as the Python implementation.
    static func resampledFloat(_ points: [Point], count: Int) -> [V2] {
        resample(points, count: count).map { V2(Double(Float($0.x)), Double(Float($0.y))) }
    }

    /// The graph's input: `count` x `[x, y]` floats.
    static func modelInput(_ points: [Point], count: Int) -> [Float] {
        normalize(resampledFloat(points, count: count)).flatMap { [Float($0.x), Float($0.y)] }
    }

    /// The stroke's arc length in canvas units.
    static func length(_ points: [Point]) -> Double {
        guard points.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<points.count {
            total += ((points[i].x - points[i - 1].x) * (points[i].x - points[i - 1].x)
                + (points[i].y - points[i - 1].y) * (points[i].y - points[i - 1].y)).squareRoot()
        }
        return total
    }
}
