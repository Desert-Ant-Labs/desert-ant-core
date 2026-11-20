enum Align {
    static let template112: [(Double, Double)] = [
        (38.2946, 51.6963), (73.5318, 51.5014), (56.0252, 71.7366), (41.5493, 92.3655), (70.7299, 92.2041),
    ]

    static let side = 128

    static func transform(_ points: [(Double, Double)], side: Int = side) -> (a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        let k = Double(side) / 112
        let dst = template112.map { ($0.0 * k, $0.1 * k) }
        let n = Double(points.count)
        let ms = (points.map(\.0).reduce(0, +) / n, points.map(\.1).reduce(0, +) / n)
        let md = (dst.map(\.0).reduce(0, +) / n, dst.map(\.1).reduce(0, +) / n)
        var a = 0.0, b = 0.0, v = 0.0
        for (s, t) in zip(points, dst) {
            let sx = s.0 - ms.0, sy = s.1 - ms.1, dx = t.0 - md.0, dy = t.1 - md.1
            a += sx * dx + sy * dy
            b += sx * dy - sy * dx
            v += sx * sx + sy * sy
        }
        let c = a / v, s = b / v
        return (c, s, -s, c, md.0 - (c * ms.0 - s * ms.1), md.1 - (s * ms.0 + c * ms.1))
    }

    static func crop(_ image: Preprocess.Plane, landmarks: [(Double, Double)]) -> Preprocess.Plane {
        var m = transform(landmarks)
        var src = image
        let scale = (m.a * m.a + m.b * m.b).squareRoot()
        if scale < 0.5 {
            let f = 2 * scale
            let w = max(1, Preprocess.pyRound(Double(image.width) * f)), h = max(1, Preprocess.pyRound(Double(image.height) * f))
            src = Preprocess.resize(image, width: w, height: h, filter: .bilinear)
            let fx = Double(image.width) / Double(w), fy = Double(image.height) / Double(h)
            m = (m.a * fx, m.b * fx, m.c * fy, m.d * fy, m.tx, m.ty)
        }
        return warp(src, m)
    }

    static func warp(_ image: Preprocess.Plane, _ m: (a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double)) -> Preprocess.Plane {
        let det = m.a * m.d - m.b * m.c
        let ia = m.d / det, ib = -m.b / det, ic = -m.c / det, id = m.a / det
        let itx = -(ia * m.tx + ic * m.ty), ity = -(ib * m.tx + id * m.ty)
        let W = image.width, H = image.height, ch = image.channels, n = side
        var out = [UInt8](repeating: 0, count: n * n * ch)
        image.bytes.withUnsafeBufferPointer { s in
            for y in 0..<n {
                for x in 0..<n {
                    let sx = ia * Double(x) + ic * Double(y) + itx, sy = ib * Double(x) + id * Double(y) + ity
                    let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
                    let fx = sx - Double(x0), fy = sy - Double(y0)
                    for c in 0..<ch {
                        func px(_ xx: Int, _ yy: Int) -> Double {
                            xx >= 0 && xx < W && yy >= 0 && yy < H ? Double(s[(yy * W + xx) * ch + c]) : 0
                        }
                        let v = (1 - fy) * ((1 - fx) * px(x0, y0) + fx * px(x0 + 1, y0))
                            + fy * ((1 - fx) * px(x0, y0 + 1) + fx * px(x0 + 1, y0 + 1))
                        out[(y * n + x) * ch + c] = UInt8(max(0, min(255, v.rounded())))
                    }
                }
            }
        }
        return Preprocess.Plane(width: n, height: n, channels: ch, bytes: out)
    }
}
