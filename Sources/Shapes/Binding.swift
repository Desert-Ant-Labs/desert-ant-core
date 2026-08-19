// Shapes' side of the cross-language binding: construction, plus the two payload
// schemas that are genuinely model-specific (the options a run takes, and what a
// result looks like). The generic handle lifecycle and the exported symbols live
// in NativeBindings and ShapesNative, so this file is only the model's adapter.

import DesertAnt

extension Shapes: BoundModel {
    /// Input payload: `u32 count`, then that many `f64 x`, `f64 y` pairs - one
    /// stroke in canvas coordinates. Nothing about the modality reaches the ABI:
    /// a stroke is just this model's payload, like text is emo's and samples are
    /// clear's.
    ///
    /// Options payload: `f64 minimumConfidence`. An empty payload means the SDK
    /// defaults.
    ///
    /// Result payload: `u32 present` (0 when the stroke was rejected or
    /// degenerate, and nothing follows); otherwise `u32 kind` (1 line,
    /// 2 rectangle, 3 triangle, 4 ellipse, 5 star) followed by that kind's
    /// fields. Points are `f64` pairs, point lists are a `u32` count then that
    /// many points.
    public func run(input: FFIReader, options: FFIReader) async -> [UInt8]? {
        var input = input
        var options = options
        let count = input.u32()
        var points: [Point] = []
        points.reserveCapacity(count)
        for _ in 0..<count {
            let x = input.f64()
            points.append(Point(x: x, y: input.f64()))
        }
        // An empty payload means the SDK defaults, so this must match the default
        // every SDK declares for `minimumConfidence` (0), not a number of its own.
        let opts = Options(minimumConfidence: options.isEmpty ? 0 : options.f64())
        // `try?` alone would flatten the two nils into one: a rejected stroke
        // (a result the host must see as "no shape") and a failed load or run
        // (a NULL buffer). They are different answers, so they are caught apart.
        let recognized: Shape?
        do { recognized = try await recognize(points: points, options: opts) }
        catch { return nil }

        var w = FFIWriter()
        guard let shape = recognized else {
            w.u32(0)
            return w.bytes
        }
        w.u32(1)
        switch shape {
        case let .line(from, to):
            w.u32(1)
            w.point(from)
            w.point(to)
        case let .rectangle(corners):
            w.u32(2)
            w.points(corners)
        case let .triangle(vertices):
            w.u32(3)
            w.points(vertices)
        case let .ellipse(center, semiMajor, semiMinor, rotation):
            w.u32(4)
            w.point(center)
            w.f64(semiMajor)
            w.f64(semiMinor)
            w.f64(rotation)
        case let .star(center, outerRadius, innerRadius, rotation, pointCount):
            w.u32(5)
            w.point(center)
            w.f64(outerRadius)
            w.f64(innerRadius)
            w.f64(rotation)
            w.u32(pointCount)
        }
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
