import RealModule

/// The model's template numbers: one kind's slice of the `numbers` output to the
/// kind's numbers on the canvas. The code matches `decode` and `canonical` in the
/// Python implementation (`models/shapes.py`, `data/templates.py` in ml-shapes).
enum Numbers {
    /// Names of numbers that are lengths: they scale with the drawing.
    static let lengths: Set<String> = ["w", "h", "a", "b", "outer", "inner", "head", "amp"]

    /// The kind's outputs to its numbers in the drawing's frame: an angle from
    /// its cos and sin, the teeth to the nearest half, then one canonical
    /// order (the same shape always has the same numbers).
    static func decode(_ kind: String, _ outputs: [Float], _ k: ShapeMeta.KindNumbers) -> [Double] {
        let v = outputs.map(Double.init)
        var out = [Double]()
        var i = 0
        for name in k.names {
            if name == "angle" {
                out.append(Double.atan2(y: v[i + 1], x: v[i]) / Double(k.symmetry ?? 1))
                i += 2
            } else if name == "teeth" {
                out.append(max(1, (v[i] * (k.teethScale ?? 1) * 2).rounded(.toNearestOrEven) / 2))
                i += 1
            } else {
                out.append(v[i])
                i += 1
            }
        }
        return canonical(kind, out)
    }

    /// Index pairs (x, y) of the numbers that are points.
    static func pairs(_ names: [String]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for (i, n) in names.enumerated() {
            if n.hasSuffix("x") && !lengths.contains(n), let j = names.firstIndex(of: String(n.dropLast()) + "y") {
                out.append((i, j))
            } else if n.hasPrefix("x"), n.count > 1, n.dropFirst().allSatisfy(\.isNumber),
                      let j = names.firstIndex(of: "y" + n.dropFirst()) {
                out.append((i, j))
            }
        }
        return out
    }

    /// Numbers in the drawing's frame to the canvas: points moved back, lengths
    /// scaled, angles and counts unchanged.
    static func toCanvas(_ v: [Double], names: [String], center: V2, scale: Double) -> [Double] {
        var out = v
        for (i, j) in pairs(names) {
            out[i] = center.x + scale * v[i]
            out[j] = center.y + scale * v[j]
        }
        for (i, n) in names.enumerated() where lengths.contains(n) { out[i] = v[i] * scale }
        return out
    }

    // MARK: Canonical

    static func canonical(_ kind: String, _ p: [Double]) -> [Double] {
        var p = p
        switch kind {
        case "rectangle", "scribble", "cloud", "heart":
            if kind == "rectangle" || kind == "scribble" {
                // a quarter turn swaps width and height: bring the angle into [-45, 45) degrees
                let q = (p[4] / (Double.pi / 2)).rounded(.toNearestOrEven)
                if Int(q) & 1 == 1 { p.swapAt(2, 3) }
                p[4] -= q * (Double.pi / 2)
            }
            p[2] = abs(p[2]); p[3] = abs(p[3])
        case "ellipse":
            var a = abs(p[2]), b = abs(p[3]), ang = p[4]
            if b > a { swap(&a, &b); ang += Double.pi / 2 }
            p[2] = a; p[3] = b
            p[4] = remainder(ang + Double.pi / 2, Double.pi) - Double.pi / 2
        case "triangle", "diamond", "pentagon", "hexagon":
            p = clockwiseFromTop(p)
        case "star":
            p[2] = abs(p[2]); p[3] = abs(p[3])
            p[4] = remainder(p[4], 2 * Double.pi / 5)
        case "line":
            // either end can come first: the left one (the top one for a vertical line)
            if p[6] < p[0] || (p[6] == p[0] && p[7] < p[1]) { p = reversedPoints(p) }
        case "zigzag":
            // walked backwards the same zigzag has its ends swapped, and with an
            // even number of runs the other side's sign: from the left end
            if p[2] < p[0] || (p[2] == p[0] && p[3] < p[1]) {
                let even = Int((2 * p[5]).rounded(.toNearestOrEven)) & 1 == 0
                p = [p[2], p[3], p[0], p[1], even ? -p[4] : p[4], p[5]]
            }
        case "bracket":
            // either end can come first: the top one
            if p[7] < p[1] { p = reversedPoints(p) }
        case "check":
            // either end can come first: the short arm's
            let first = hypot(p[0] - p[2], p[1] - p[3]), last = hypot(p[4] - p[2], p[5] - p[3])
            if first > last { p = reversedPoints(p) }
        case "plus":
            // the more level stroke first, from its left end; the more upright one second, from its upper end
            var s = [[p[0], p[1], p[2], p[3]], [p[4], p[5], p[6], p[7]]]
            func level(_ k: Int) -> Bool { abs(s[k][2] - s[k][0]) >= abs(s[k][3] - s[k][1]) }
            if !level(0) && level(1) { s.swapAt(0, 1) }
            if s[0][2] < s[0][0] { s[0] = [s[0][2], s[0][3], s[0][0], s[0][1]] }
            if s[1][3] < s[1][1] { s[1] = [s[1][2], s[1][3], s[1][0], s[1][1]] }
            p = s[0] + s[1]
        case "cross":
            // each stroke from its upper end; the stroke whose upper end is further left first
            var s = [[p[0], p[1], p[2], p[3]], [p[4], p[5], p[6], p[7]]]
            for k in 0..<2 where s[k][3] < s[k][1] { s[k] = [s[k][2], s[k][3], s[k][0], s[k][1]] }
            if s[0][0] > s[1][0] { s.swapAt(0, 1) }
            p = s[0] + s[1]
        default:
            break
        }
        return p
    }

    /// The point list in reverse order.
    private static func reversedPoints(_ p: [Double]) -> [Double] {
        stride(from: p.count - 2, through: 0, by: -2).flatMap { [p[$0], p[$0 + 1]] }
    }

    /// A polygon's vertices clockwise on screen (y down), from the top vertex.
    private static func clockwiseFromTop(_ p: [Double]) -> [Double] {
        let n = p.count / 2
        var v = (0..<n).map { V2(p[2 * $0], p[2 * $0 + 1]) }
        var area = 0.0
        for i in 0..<n { area += v[i].x * v[(i + 1) % n].y - v[(i + 1) % n].x * v[i].y }
        if area < 0 { v.reverse() }
        var top = 0
        for i in 1..<n where v[i].y + 1e-3 * v[i].x < v[top].y + 1e-3 * v[top].x { top = i }
        return (0..<n).flatMap { [v[(top + $0) % n].x, v[(top + $0) % n].y] }
    }

    /// The remainder with the divisor's sign, as torch's: in `[0, m)` for `m > 0`.
    private static func remainder(_ a: Double, _ m: Double) -> Double {
        let r = a.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + m : r
    }

    private static func hypot(_ x: Double, _ y: Double) -> Double { (x * x + y * y).squareRoot() }
}
