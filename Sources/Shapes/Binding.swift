import DesertAnt

/// Wire numbers for ``Shape/Kind``, shared with `packages/shapes-node/codec.js`
/// and `packages/shapes-kotlin`. A number never changes meaning, and a new kind
/// gets the next free number. 17 was the lasso, which no released model
/// returns: it stays unused.
let wireKinds: [Shape.Kind: Int] = [
    .line: 1, .rectangle: 2, .triangle: 3, .ellipse: 4, .star: 5,
    .curve: 6, .arrow: 7, .diamond: 8, .pentagon: 9, .hexagon: 10,
    .heart: 11, .cloud: 12, .scribble: 13,
    .check: 14, .cross: 15, .bracket: 16, .zigzag: 18, .plus: 19,
]

/// The number of points in the outline at the end of every payload.
let wireOutlineSamples = 64

extension Shapes: BoundModel {
    /// Input payload: one drawing in canvas coordinates. `u32 strokes`, then
    /// for each stroke `u32 count`, `u32 timed` (1 when every point carries a
    /// time), and `count` points, each `f64 x`, `f64 y` and, when timed, `f64 t`
    /// in milliseconds (see ``Stroke/times``).
    ///
    /// Options payload: `f64 minimumConfidence`, `u32 rotation` (0 snapped,
    /// 1 upright, 2 free), `u32 kinds`, a bit mask with bit `n` for wire kind
    /// `n` (0 means every kind), and `u32 finished` (1, the default, or 0 for a
    /// preview while the pen still moves; see ``Options/isFinished``). A host
    /// can leave out fields from the end, and an empty payload means the SDK
    /// defaults.
    ///
    /// Result payload: `u32 present`, which is 0 for a drawing that isn't a
    /// shape, with nothing after it. Otherwise `u32 kind` (`wireKinds`) follows,
    /// then that kind's fields, then the outline (see ``Shape/outline(samples:)``).
    /// A point is two `f64` values, a point list is a `u32` count and then the
    /// points, and a flag is a `u32` 0 or 1.
    public func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var input = input
        var options = options
        var strokes: [Stroke] = []
        // A count larger than the bytes behind it is untrusted input: read as
        // many strokes and points as the payload holds, never past its end.
        let strokeCount = min(input.u32(), input.remaining / 8)
        for _ in 0..<strokeCount {
            let claimed = input.u32()
            let timed = input.u32() == 1
            let count = min(claimed, input.remaining / (timed ? 24 : 16))
            var stroke = Stroke(points: [])
            stroke.points.reserveCapacity(count)
            for _ in 0..<count {
                let x = input.f64()
                stroke.points.append(Point(x: x, y: input.f64()))
                if timed { stroke.times.append(input.f64()) }
            }
            strokes.append(stroke)
        }
        // Defaults here must match what every SDK declares.
        var opts = Options()
        if options.remaining >= 8 { opts.minimumConfidence = Options(minimumConfidence: options.f64()).minimumConfidence }
        if options.remaining >= 4 { opts.rotation = [.snapped, .upright, .free][min(max(options.u32(), 0), 2)] }
        if options.remaining >= 4 {
            let mask = options.u32()
            if mask != 0 { opts.kinds = Set(wireKinds.filter { mask & (1 << $0.value) != 0 }.keys) }
        }
        if options.remaining >= 4 { opts.isFinished = options.u32() != 0 }
        // `try?` alone would merge two different nils: a stroke that isn't a
        // shape (a result) and a failed load or run (a NULL buffer).
        let recognized: Shape?
        do { recognized = try await recognize(strokes: strokes, options: opts) }
        catch { return nil }

        var w = FFIWriter()
        guard let shape = recognized else {
            w.u32(0)
            return w.bytes
        }
        w.u32(1)
        w.u32(wireKinds[shape.kind]!)
        switch shape {
        case let .line(from, to):
            w.point(from); w.point(to)
        case let .curve(from, c1, c2, to):
            w.point(from); w.point(c1); w.point(c2); w.point(to)
        case let .arrow(from, c1, c2, to, startHead, endHead):
            w.point(from); w.point(c1); w.point(c2); w.point(to)
            w.u32(startHead ? 1 : 0); w.u32(endHead ? 1 : 0)
        case let .rectangle(corners):
            w.points(corners)
        case let .ellipse(center, semiMajor, semiMinor, rotation):
            w.point(center); w.f64(semiMajor); w.f64(semiMinor); w.f64(rotation)
        case let .triangle(vs), let .diamond(vs), let .pentagon(vs), let .hexagon(vs):
            w.points(vs)
        case let .star(center, outerRadius, innerRadius, rotation, pointCount):
            w.point(center); w.f64(outerRadius); w.f64(innerRadius); w.f64(rotation); w.u32(pointCount)
        case let .heart(center, width, height):
            w.point(center); w.f64(width); w.f64(height)
        case let .cloud(outline):
            w.points(outline)
        case let .scribble(hull):
            w.points(hull)
        case let .check(start, corner, end):
            w.point(start); w.point(corner); w.point(end)
        case let .cross(firstFrom, firstTo, secondFrom, secondTo), let .plus(firstFrom, firstTo, secondFrom, secondTo):
            w.point(firstFrom); w.point(firstTo); w.point(secondFrom); w.point(secondTo)
        case let .bracket(points):
            w.points(points)
        case let .zigzag(from, to, amplitude, teeth):
            w.point(from); w.point(to); w.f64(amplitude); w.f64(teeth)
        }
        w.points(shape.outline(samples: wireOutlineSamples))
        return w.bytes
    }
}

private extension FFIWriter {
    mutating func point(_ p: Point) {
        f64(p.x)
        f64(p.y)
    }

    mutating func points(_ ps: [Point]) {
        u32(ps.count)
        for p in ps { point(p) }
    }
}

/// How the generic bindings construct Shapes.
public enum ShapesBinding: ModelBinding {
    public static let id = ShapesModel.id

    public static func make(cacheRoot: String?, directory: String?) -> any BoundModel {
        Shapes(directory: directory, cacheRoot: cacheRoot)
    }
}
