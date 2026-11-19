import RealModule

/// One point of ink: canvas coordinates and the time it was drawn, in
/// milliseconds on any clock that runs forward.
struct InkPoint: Sendable, Equatable {
    var x: Double
    var y: Double
    var t: Double
}

/// The model's input: a drawing of a few strokes as a fixed number of points
/// with the values the model's meta lists for each (five, or six with time),
/// and each point's stroke index. The code matches the
/// Python implementation the model was trained with (`preprocessing/ink.py` in
/// ml-shapes), and `Tests/Fixtures/shapes-v2-parity.json` holds that
/// implementation's outputs.
enum Ink {
    /// Every value a point can carry, in the order the model reads them.
    static let channels = ["x", "y", "dx", "dy", "start", "log1p_dt"]

    struct Prepared {
        /// `count` x the channels: x, y, dx, dy, stroke start, and log(1 + dt) for a model that reads time.
        let x: [Float]
        /// `count` stroke indices.
        let stroke: [Int32]
        /// The drawing's frame: its bounding box's center and longer side. The
        /// model's numbers are in this frame.
        let center: V2
        let scale: Double
    }

    /// Empty strokes are dropped and at most `min(maxStrokes, count / 2)` kept,
    /// so every stroke keeps two points. `nil` for a drawing with no points.
    static func kept(_ strokes: [[InkPoint]], count: Int, maxStrokes: Int) -> [[InkPoint]]? {
        let kept = Array(strokes.filter { !$0.isEmpty }.prefix(min(maxStrokes, count / 2)))
        return kept.isEmpty ? nil : kept
    }

    /// The bounding box's center and its longer side (1 for a drawing with no extent).
    static func frame(_ strokes: [[InkPoint]]) -> (center: V2, scale: Double) {
        let first = strokes[0][0]
        var lo = V2(first.x, first.y), hi = lo
        for s in strokes { for p in s { lo = vmin(lo, V2(p.x, p.y)); hi = vmax(hi, V2(p.x, p.y)) } }
        let side = max(hi.x - lo.x, hi.y - lo.y)
        return ((lo + hi) / 2, side > 0 ? side : 1)
    }

    /// Points per stroke: two each, the rest in proportion to arc length (the
    /// floor of each share, then one more each to the largest remainders, ties
    /// to the earlier stroke), summing to `count`.
    static func allocate(_ lengths: [Double], count n: Int) -> [Int] {
        let s = lengths.count
        var counts = Array(repeating: 2, count: s)
        let spare = n - 2 * s
        guard spare > 0 else { return counts }
        let total = lengths.reduce(0, +)
        let share = total > 0 ? lengths.map { $0 / total } : Array(repeating: 1 / Double(s), count: s)
        let extra = share.map { Int(($0 * Double(spare)).rounded(.down)) }
        for i in 0..<s { counts[i] += extra[i] }
        let left = spare - extra.reduce(0, +)
        let remainder = (0..<s).map { share[$0] * Double(spare) - Double(extra[$0]) }
        let order = (0..<s).sorted { remainder[$0] > remainder[$1] || (remainder[$0] == remainder[$1] && $0 < $1) }
        for i in order.prefix(left) { counts[i] += 1 }
        return counts
    }

    /// `n` points evenly spaced by arc length, both ends kept, with the time
    /// interpolated along with the position. A stroke with no length repeats its
    /// first point, its times spread from its first to its last.
    static func resample(_ s: [InkPoint], count n: Int) -> [InkPoint] {
        var cum = [0.0]
        cum.reserveCapacity(s.count)
        for i in 1..<max(s.count, 1) {
            cum.append(cum[i - 1] + hypot(s[i].x - s[i - 1].x, s[i].y - s[i - 1].y))
        }
        let total = cum[cum.count - 1]
        let t0 = s[0].t, t1 = s[s.count - 1].t
        if !(total > 0) || s.count == 1 {
            return (0..<n).map { j in
                InkPoint(x: s[0].x, y: s[0].y, t: j == n - 1 ? t1 : t0 + (t1 - t0) * Double(j) / Double(n - 1))
            }
        }
        var out = [InkPoint]()
        out.reserveCapacity(n)
        var idx = 0
        for j in 0..<n {
            let target = j == n - 1 ? total : total * Double(j) / Double(n - 1)
            // numpy's interp: the last knot at or before the target, so a
            // zero-length segment is skipped; the end lands on the last point
            while idx + 1 < cum.count && cum[idx + 1] <= target { idx += 1 }
            if idx == cum.count - 1 { out.append(s[idx]); continue }
            let f = (target - cum[idx]) / (cum[idx + 1] - cum[idx])
            let a = s[idx], b = s[idx + 1]
            out.append(InkPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f, t: a.t + (b.t - a.t) * f))
        }
        return out
    }

    /// The drawing's points in its frame, as float32 like the Python
    /// implementation's, with their times, stroke starts and stroke indices.
    struct Points {
        let x: [Float], y: [Float], t: [Float], start: [Float]
        let stroke: [Int32]
        let center: V2
        let scale: Double
    }

    static func points(_ drawing: [[InkPoint]], count n: Int, maxStrokes: Int) -> Points? {
        guard let strokes = kept(drawing, count: n, maxStrokes: maxStrokes) else { return nil }
        let (center, scale) = frame(strokes)
        let lengths = strokes.map { s in
            (1..<max(s.count, 1)).reduce(0.0) { $0 + hypot(s[$1].x - s[$1 - 1].x, s[$1].y - s[$1 - 1].y) }
        }
        let counts = allocate(lengths, count: n)
        let t0 = strokes.map { $0[0].t }.min()!
        var xs = [Float](), ys = [Float](), ts = [Float](), start = [Float](), stroke = [Int32]()
        for (i, (s, c)) in zip(strokes, counts).enumerated() {
            for (j, p) in resample(s, count: c).enumerated() {
                xs.append(Float((p.x - center.x) / scale))
                ys.append(Float((p.y - center.y) / scale))
                ts.append(Float(p.t - t0))
                start.append(j == 0 ? 1 : 0)
                stroke.append(Int32(i))
            }
        }
        return Points(x: xs, y: ys, t: ts, start: start, stroke: stroke, center: center, scale: scale)
    }

    /// The drawing as the model reads it: `channels` by name, in order, and
    /// 0 in every channel of `zero`.
    static func prepare(_ drawing: [[InkPoint]], count n: Int, maxStrokes: Int,
                        channels: [String] = Ink.channels, zero: Set<String> = []) -> Prepared? {
        guard let p = points(drawing, count: n, maxStrokes: maxStrokes) else { return nil }
        // The Python implementation computes the steps in float32.
        var x = [Float]()
        x.reserveCapacity(n * channels.count)
        for i in 0..<n {
            let first = i == 0 || p.start[i] == 1
            for c in channels {
                if zero.contains(c) { x.append(0); continue }
                switch c {
                case "x": x.append(p.x[i])
                case "y": x.append(p.y[i])
                case "dx": x.append(first ? 0 : p.x[i] - p.x[i - 1])
                case "dy": x.append(first ? 0 : p.y[i] - p.y[i - 1])
                case "start": x.append(p.start[i])
                case "log1p_dt": x.append(Float.log(onePlus: i == 0 ? 0 : max(0, p.t[i] - p.t[i - 1])))
                default: return nil
                }
            }
        }
        return Prepared(x: x, stroke: p.stroke, center: p.center, scale: p.scale)
    }

    /// The drawing's points in its frame for the template fit and its residual.
    static func framePoints(_ drawing: [[InkPoint]], count n: Int, maxStrokes: Int) -> [V2]? {
        points(drawing, count: n, maxStrokes: maxStrokes).map { p in zip(p.x, p.y).map { V2(Double($0), Double($1)) } }
    }
}

private func hypot(_ x: Double, _ y: Double) -> Double { (x * x + y * y).squareRoot() }
