import DesertAnt
import RealModule

/// One recognition: `Model` prepares the drawing, runs the model, reads the top
/// kind and its numbers, fits the template to the ink, checks the gate, and
/// snaps the shape per `Options`.
final class Model: @unchecked Sendable {
    private let session: any InferenceSession
    let meta: ShapeMeta

    /// A drawing shorter than this, in canvas units, is a tap.
    static let minimumLength = 6.0
    /// The largest coordinate taken, in canvas units, either sign. Far past any
    /// canvas, and small enough that no length or square measured from the ink
    /// overflows; a drawing beyond it, or with a coordinate that is not finite,
    /// comes back `nil`.
    static let largestCoordinate = 1e9
    /// Milliseconds between points, and between strokes, when strokes come
    /// without times: the medians of the real drawings the model was checked
    /// on. Without times the model still loses some accuracy (ml-shapes
    /// report_2026-11-13_sdk_fit_and_times).
    static let assumedInterval = 16.0
    static let assumedPause = 450.0
    /// The largest deviation of a curve's controls from its chord, over the
    /// chord's length, for which a connector is straight.
    static let straightTolerance = 0.06
    /// Outline further than this from the ink, over the ink's larger side, is
    /// undrawn (ml-shapes `fit.FAR`).
    static let far = 0.1
    /// The most of a fitted outline that may be undrawn for the shape to snap,
    /// for a kind the meta's `undrawn_limits` does not tune.
    /// The model guesses a shape from its start while it is drawn; the shape
    /// snaps only once its outline is drawn (Berkay, 2026-11-14). Training keeps
    /// a fit as a number target by the same rule (ml-shapes `fit.UNDRAWN_MAX`).
    /// A square missing one side has 20% of its outline undrawn and does not
    /// snap; a hexagon missing one of six, 9%, and snaps (the open side's ends
    /// lie near the ink).
    static let maximumUndrawn = 0.15

    init(assets: ModelAssets) throws {
        session = assets.session
        meta = try ShapeMeta(json: assets.metaJSON)
    }

    /// What the model reads in a drawing.
    struct Reading: Sendable {
        /// Every kind's probability, in `ShapeMeta.kinds` order.
        let probs: [Float]
        /// The most likely kind's index and name.
        let top: Int
        let kind: String
        /// That kind's numbers in the drawing's frame and on the canvas, in its
        /// template's order; `nil` for `none`.
        let frameNumbers: [Double]?
        let numbers: [Double]?
        /// The drawing's frame: its bounding box's center and longer side.
        let center: V2
        let scale: Double
        /// The raw outputs, for tests.
        let logits: [Float]
        let rawNumbers: [Float]
    }

    /// One forward pass over a drawing of a few strokes. `nil` for a drawing
    /// with no points.
    func read(_ drawing: [[InkPoint]]) async throws -> Reading? {
        let n = meta.pointCount
        guard let prepared = Ink.prepare(drawing, count: n, maxStrokes: meta.maxStrokes,
                                         channels: meta.channels, zero: meta.zeroChannels) else { return nil }
        let outputs = try await session.run(
            inputs: ["x": Tensor(float32: prepared.x, shape: [1, n, meta.channels.count]),
                     "stroke": Tensor(int32: prepared.stroke, shape: [1, n])],
            outputs: ["kind_logits", "numbers"])
        guard outputs.count == 2,
              let logits = outputs[0].float32Values, logits.count == meta.kinds.count,
              let raw = outputs[1].float32Values, raw.count == meta.numbersWidth else {
            throw ShapesError.predictionFailed
        }
        var top = 0
        for i in logits.indices where logits[i] > logits[top] { top = i }
        let peak = logits[top]
        let exps = logits.map { Float.exp($0 - peak) }
        let sum = exps.reduce(0, +)
        let kind = meta.kinds[top]
        var frame: [Double]?, numbers: [Double]?
        if let k = meta.numbers[kind] {
            frame = Numbers.decode(kind, Array(raw[k.offset..<(k.offset + k.outputs.count)]), k)
            numbers = Numbers.toCanvas(frame!, names: k.names, center: prepared.center, scale: prepared.scale)
        }
        return Reading(probs: exps.map { $0 / sum }, top: top, kind: kind, frameNumbers: frame, numbers: numbers,
                       center: prepared.center, scale: prepared.scale, logits: logits, rawNumbers: raw)
    }

    /// The strokes as the model reads them: their own times when every stroke
    /// has one per point, otherwise a steady pace with a pause between strokes.
    static func ink(_ strokes: [Stroke]) -> [[InkPoint]] {
        let timed = !strokes.isEmpty && strokes.allSatisfy { $0.times.count == $0.points.count }
        var clock = 0.0
        return strokes.map { s in
            if timed { return zip(s.points, s.times).map { InkPoint(x: $0.x, y: $0.y, t: $1) } }
            defer { clock += Double(max(s.points.count - 1, 0)) * assumedInterval + assumedPause }
            return s.points.enumerated().map { InkPoint(x: $1.x, y: $1.y, t: clock + Double($0) * assumedInterval) }
        }
    }

    func recognize(strokes: [Stroke], options: Options) async throws -> Shape? {
        try await inspect(strokes: strokes, options: options).shape
    }

    /// One recognition with what led to it: every kind's probability, the fit's
    /// residual against the kind's gate, why a drawing came back `nil`, and the
    /// time the model and the fit took.
    func inspect(strokes: [Stroke], options: Options) async throws -> Inspection {
        let strokes = strokes.filter { !$0.points.isEmpty }
        // untrusted input from every binding: never let an infinite or NaN
        // length reach the point allocation
        guard strokes.allSatisfy({ $0.points.allSatisfy { abs($0.x) <= Self.largestCoordinate && abs($0.y) <= Self.largestCoordinate } }) else {
            return Inspection(rejection: .invalid)
        }
        guard strokes.reduce(0, { $0 + $1.points.count }) >= 2,
              strokes.reduce(0.0, { $0 + Preprocess.length($1.points) }) >= Self.minimumLength else {
            return Inspection(rejection: .tap)
        }
        let ink = Self.ink(strokes)
        let clock = ContinuousClock()
        let start = clock.now
        guard let reading = try await read(ink) else { return Inspection(rejection: .tap) }
        let modelTime = clock.now - start
        let kinds = zip(meta.kinds, reading.probs).map { (name: $0, probability: Double($1)) }
            .sorted { $0.probability > $1.probability }
        var out = Inspection(kinds: kinds, modelMilliseconds: Self.milliseconds(modelTime))
        if meta.rejects.contains(reading.top) { out.rejection = .notAShape; return out }
        if Double(reading.probs[reading.top]) < options.minimumConfidence { out.rejection = .confidence; return out }
        let fitStart = clock.now
        let fit = shape(reading, ink: ink, strokes: strokes)
        out.fitMilliseconds = Self.milliseconds(clock.now - fitStart)
        out.residual = fit.residual
        out.gate = meta.residGates[reading.kind]
        guard let shape = fit.shape else { out.rejection = .gate; return out }
        if Self.outlines.contains(shape.kind) {
            let gap = Self.undrawn(shape, ink: ink)
            let limit = meta.undrawnLimits[reading.kind] ?? Self.maximumUndrawn
            out.undrawn = gap
            out.maximumUndrawn = limit
            // the outline is waited for only at the snap; a preview while the pen moves shows what is coming
            guard !options.isFinished || gap <= limit else { out.rejection = .undrawn; return out }
        }
        let snapped = Snapping.apply(shape, rotation: options.rotation)
        // The model's `line` fits as a line or a curve, so the kinds filter
        // checks the fitted shape.
        guard options.kinds.contains(snapped.kind) else { out.rejection = .kinds; return out }
        out.shape = snapped
        return out
    }

    /// The kinds with a closed outline, the ones a snap waits for: a half-drawn
    /// rectangle or ellipse is not one yet. Open marks are left out: a check's
    /// or an arrow's fitted template reaches past ink drawn short (a first arm
    /// of 5%, small barbs), so on Berkay's complete checks and arrows 17 to 50%
    /// of it measured undrawn and they were refused; a zigzag stopped early is a
    /// zigzag with fewer teeth, and a scribble's outline is the ink itself.
    static let outlines: Set<Shape.Kind> = [.rectangle, .ellipse, .triangle, .diamond, .pentagon, .hexagon,
                                            .star, .heart, .cloud]

    /// The share of the shape's outline, by length, further than `far` times
    /// the ink's larger side from any ink: the outline's distance to the ink,
    /// the residual's other direction (ml-shapes `fit.undrawn`, measured here on
    /// the canvas and against the ink filled in along its strokes).
    static func undrawn(_ shape: Shape, ink: [[InkPoint]], samples m: Int = 96) -> Double {
        var paths = shape.paths().map { $0.map { V2($0.x, $0.y) } }.filter { $0.count >= 2 }
        if shape.isClosed { paths = paths.map { $0 + [$0[0]] } }
        let all = ink.flatMap { $0 }
        guard !paths.isEmpty, let first = all.first else { return 0 }
        var lo = V2(first.x, first.y), hi = lo
        for q in all { lo = vmin(lo, V2(q.x, q.y)); hi = vmax(hi, V2(q.x, q.y)) }
        let size = max(hi.x - lo.x, hi.y - lo.y, 1e-9)
        // the ink as segments (a one-point stroke as a segment of no length), so
        // the distance is to the ink itself however far apart its points are
        var inkSegs: [(V2, V2)] = []
        for s in ink {
            if s.count == 1 { inkSegs.append((V2(s[0].x, s[0].y), V2(s[0].x, s[0].y))) }
            for (a, b) in zip(s, s.dropFirst()) { inkSegs.append((V2(a.x, a.y), V2(b.x, b.y))) }
        }
        // m points evenly spaced by length over all the paths together
        var segs: [(V2, V2)] = []
        for path in paths { for (a, b) in zip(path, path.dropFirst()) { segs.append((a, b)) } }
        let total = segs.reduce(0.0) { $0 + ($1.1 - $1.0).length }
        guard total > 0 else { return 0 }
        var far = 0, i = 0, start = 0.0
        for j in 0..<m {
            let target = total * Double(j) / Double(m - 1)
            while i < segs.count - 1, start + (segs[i].1 - segs[i].0).length < target {
                start += (segs[i].1 - segs[i].0).length
                i += 1
            }
            let (a, b) = segs[i]
            let len = (b - a).length
            let q = a + (b - a) * (len > 0 ? min(max((target - start) / len, 0), 1) : 0)
            var best = Double.infinity
            for (p, r) in inkSegs { best = min(best, Self.distance(q, toSegment: p, r)) }
            if best / size > Self.far { far += 1 }
        }
        return Double(far) / Double(m)
    }

    /// The distance from `q` to the segment from `a` to `b`.
    static func distance(_ q: V2, toSegment a: V2, _ b: V2) -> Double {
        let d = b - a
        let l2 = d.x * d.x + d.y * d.y
        let t = l2 > 0 ? min(max(((q.x - a.x) * d.x + (q.y - a.y) * d.y) / l2, 0), 1) : 0
        return (q - (a + d * t)).length
    }

    private static func milliseconds(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// The fitted shape, `nil` when the fit misses the kind's gate, with the
    /// fit's residual. One stroke of a kind the geometric fitters cover (all of
    /// v1's but the arrow) goes through them, as in v1; everything else through
    /// the template fit from the model's numbers.
    private func shape(_ reading: Reading, ink: [[InkPoint]], strokes: [Stroke]) -> (shape: Shape?, residual: Double?) {
        let gate = meta.residGates[reading.kind] ?? .infinity
        if strokes.count == 1, let kind = Shape.Kind(rawValue: reading.kind), kind != .arrow, Fitter.covers.contains(kind) {
            let fit = Fitter.fit(kind, points: strokes[0].points, head: [], straightTolerance: Self.straightTolerance)
            return (fit.residual <= gate ? fit.shape : nil, fit.residual)
        }
        guard let start = reading.frameNumbers, let k = meta.numbers[reading.kind],
              let points = Ink.framePoints(ink, count: TemplateFit.pointCount, maxStrokes: meta.maxStrokes) else { return (nil, nil) }
        let fit = TemplateFit.fit(reading.kind, points: points, from: start)
        guard fit.residual <= gate else { return (nil, fit.residual) }
        let v = Numbers.toCanvas(fit.numbers, names: k.names, center: reading.center, scale: reading.scale)
        return (Self.shape(reading.kind, v, ink: ink, center: reading.center, scale: reading.scale, frame: fit.numbers), fit.residual)
    }

    /// A kind's fitted numbers on the canvas as a `Shape`.
    static func shape(_ kind: String, _ v: [Double], ink: [[InkPoint]], center: V2, scale: Double, frame: [Double]) -> Shape? {
        func pt(_ i: Int) -> Point { Point(x: v[i], y: v[i + 1]) }
        func pts(_ n: Int) -> [Point] { (0..<n).map { pt(2 * $0) } }
        switch kind {
        case "line", "arrow":
            let (a, c1, c2, b) = (pt(0), pt(2), pt(4), pt(6))
            let straight = straightness(a, c1, c2, b) <= straightTolerance
            if kind == "line" {
                return straight ? .line(from: a, to: b) : .curve(from: a, control1: c1, control2: c2, to: b)
            }
            let (s1, s2) = straight ? (onChord(a, b, 1.0 / 3), onChord(a, b, 2.0 / 3)) : (c1, c2)
            return .arrow(from: a, control1: s1, control2: s2, to: b, startHead: false, endHead: true)
        case "rectangle":
            let c = V2(v[0], v[1]), m = Mat2.rotation(v[4])
            return .rectangle(corners: [V2(-0.5, -0.5), V2(0.5, -0.5), V2(0.5, 0.5), V2(-0.5, 0.5)].map {
                let q = c + m * V2($0.x * v[2], $0.y * v[3])
                return Point(x: q.x, y: q.y)
            })
        case "ellipse":
            return .ellipse(center: pt(0), semiMajor: v[2], semiMinor: v[3], rotation: v[4])
        case "triangle": return .triangle(vertices: pts(3))
        case "diamond": return .diamond(vertices: pts(4))
        case "pentagon": return .pentagon(vertices: pts(5))
        case "hexagon": return .hexagon(vertices: pts(6))
        case "star":
            return .star(center: pt(0), outerRadius: v[2], innerRadius: v[3], rotation: v[4], pointCount: 5)
        case "heart":
            return .heart(center: pt(0), width: v[2], height: v[3])
        case "cloud":
            var outline = TemplateFit.parts("cloud", frame, n: 12)[0].map { Point(x: center.x + scale * $0.x, y: center.y + scale * $0.y) }
            outline.removeLast()
            return .cloud(outline: outline)
        case "scribble":
            let all = ink.flatMap { $0 }.map { V2($0.x, $0.y) }
            let hull = Fitter.convexHull(all)
            return .scribble(hull: (hull.count >= 3 ? hull : all).map { Point(x: $0.x, y: $0.y) })
        case "check":
            return .check(start: pt(0), corner: pt(2), end: pt(4))
        case "cross":
            return .cross(firstFrom: pt(0), firstTo: pt(2), secondFrom: pt(4), secondTo: pt(6))
        case "plus":
            return .plus(firstFrom: pt(0), firstTo: pt(2), secondFrom: pt(4), secondTo: pt(6))
        case "bracket":
            return .bracket(points: pts(4))
        case "zigzag":
            // the sign is the side of the first run, as fitted
            return .zigzag(from: pt(0), to: pt(2), amplitude: v[4], teeth: v[5])
        default:
            return nil
        }
    }

    /// The controls' largest distance from the chord, over the chord's length.
    private static func straightness(_ a: Point, _ c1: Point, _ c2: Point, _ b: Point) -> Double {
        let d = V2(b.x - a.x, b.y - a.y), length = d.length
        guard length > 0 else { return .infinity }
        func off(_ c: Point) -> Double { abs(crossZ(d, V2(c.x - a.x, c.y - a.y))) / length }
        return max(off(c1), off(c2)) / length
    }

    private static func onChord(_ a: Point, _ b: Point, _ f: Double) -> Point {
        Point(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }
}
