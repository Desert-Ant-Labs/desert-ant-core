import DesertAnt
import RealModule

enum Decode {
    static func sigmoid(_ x: Float) -> Double { 1 / (1 + Double.exp(-Double(x))) }

    struct Candidate {
        var confidence: Double
        var x0, y0, x1, y1: Double
        var landmarks: [(Double, Double)]

        var area: Double { max(0, x1 - x0) * max(0, y1 - y0) }

        func scaled(by k: Double) -> Candidate {
            Candidate(confidence: confidence, x0: x0 * k, y0: y0 * k, x1: x1 * k, y1: y1 * k, landmarks: landmarks.map { ($0.0 * k, $0.1 * k) })
        }
    }

    static func peaks(_ heatmap: [Float], h: Int, w: Int, k: Int = 300, threshold: Double = 0.05) -> [(y: Int, x: Int, p: Double)] {
        let floor = Float(Double.log(threshold / (1 - threshold)))
        var found: [(y: Int, x: Int, p: Double)] = []
        for y in 0..<h {
            for x in 0..<w {
                let v = heatmap[y * w + x]
                guard v >= floor else { continue }
                var peak = true
                for dy in -1...1 where peak {
                    for dx in -1...1 {
                        let yy = y + dy, xx = x + dx
                        if yy >= 0, yy < h, xx >= 0, xx < w, heatmap[yy * w + xx] > v { peak = false; break }
                    }
                }
                if peak { found.append((y, x, sigmoid(v))) }
            }
        }
        return Array(found.sorted { $0.p > $1.p }.prefix(k))
    }

    static func faces(heatmap: [Float], size: [Float], offset: [Float], landmarks: [Float], h: Int, w: Int,
                      stride: Double = 4) -> [Candidate] {
        let n = h * w
        return peaks(heatmap, h: h, w: w).map { p in
            let i = p.y * w + p.x
            let cx = (Double(p.x) + Double(offset[i])) * stride, cy = (Double(p.y) + Double(offset[n + i])) * stride
            let bw = Double.exp(Double(size[i])) * stride, bh = Double.exp(Double(size[n + i])) * stride
            let points = (0..<5).map { j in
                (cx + Double(landmarks[(2 * j) * n + i]) * bw, cy + Double(landmarks[(2 * j + 1) * n + i]) * bh)
            }
            return Candidate(confidence: p.p, x0: cx - bw / 2, y0: cy - bh / 2, x1: cx + bw / 2, y1: cy + bh / 2,
                             landmarks: points)
        }
    }

    static func iou(_ a: Candidate, _ b: Candidate) -> Double {
        let iw = max(0, min(a.x1, b.x1) - max(a.x0, b.x0)), ih = max(0, min(a.y1, b.y1) - max(a.y0, b.y0))
        let inter = iw * ih, union = a.area + b.area - inter
        return union > 0 ? inter / union : 0
    }

    static func nms(_ boxes: [Candidate], iou t: Double = 0.4) -> [Candidate] {
        var keep: [Candidate] = []
        for d in boxes.sorted(by: { $0.confidence > $1.confidence }) where !keep.contains(where: { iou($0, d) > t }) {
            keep.append(d)
        }
        return keep
    }
}
