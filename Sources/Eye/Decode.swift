import DesertAnt
import RealModule

/// Raw outputs to results, as ml-eye decodes them: the CenterNet box heads
/// (`train_pet_det.decode`, `nms`), the face detector (`detector.decode`) and the
/// analyzer's readout (`analyzer.readout`).
enum Decode {
    static func sigmoid(_ x: Float) -> Double { 1 / (1 + Double.exp(-Double(x))) }

    static func softmax(_ x: [Float]) -> [Double] {
        let m = Double(x.max() ?? 0)
        let e = x.map { Double.exp(Double($0) - m) }
        let s = e.reduce(0, +)
        return e.map { $0 / s }
    }

    static func named(_ names: [String], _ values: [Double]) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: zip(names, values))
    }

    /// A candidate box: label index, confidence, corners (any unit), and for faces
    /// the 5 landmarks.
    struct Candidate {
        var label: Int
        var confidence: Double
        var x0, y0, x1, y1: Double
        var landmarks: [(Double, Double)] = []

        var area: Double { max(0, x1 - x0) * max(0, y1 - y0) }
    }

    /// Peaks of a `(classes, h, w)` logit heatmap that are the max of their 3x3
    /// neighbourhood, the `k` strongest across classes at or above `threshold`,
    /// as `(class, y, x, probability)`.
    static func peaks(_ heatmap: [Float], classes: Int, h: Int, w: Int, k: Int, threshold: Double)
        -> [(c: Int, y: Int, x: Int, p: Double)] {
        var found: [(c: Int, y: Int, x: Int, p: Double)] = []
        for c in 0..<classes {
            let base = c * h * w
            for y in 0..<h {
                for x in 0..<w {
                    let v = heatmap[base + y * w + x]
                    var peak = true
                    for dy in -1...1 where peak {
                        for dx in -1...1 {
                            let yy = y + dy, xx = x + dx
                            if yy >= 0, yy < h, xx >= 0, xx < w, heatmap[base + yy * w + xx] > v { peak = false; break }
                        }
                    }
                    if peak { found.append((c, y, x, sigmoid(v))) }
                }
            }
        }
        // topk then the threshold, as the reference
        return found.sorted { $0.p > $1.p }.prefix(k).filter { $0.p >= threshold }
    }

    /// The box heads of `spatial` (48x48, offsets and log sizes shared by the
    /// classes), boxes in `0...1`.
    static func boxes(heatmap: [Float], size: [Float], offset: [Float], classes: Int, h: Int = 48, w: Int = 48) -> [Candidate] {
        peaks(heatmap, classes: classes, h: h, w: w, k: 20, threshold: 0.05).map { p in
            let i = p.y * w + p.x
            let cx = (Double(p.x) + Double(offset[i])) / Double(w), cy = (Double(p.y) + Double(offset[h * w + i])) / Double(h)
            let bw = Double.exp(Double(size[i])) / Double(w), bh = Double.exp(Double(size[h * w + i])) / Double(h)
            return Candidate(label: p.c, confidence: p.p, x0: cx - bw / 2, y0: cy - bh / 2, x1: cx + bw / 2, y1: cy + bh / 2)
        }
    }

    /// `faces_detect` (stride 4 on the letterboxed frame): boxes and landmarks in
    /// letterbox pixels.
    static func faces(heatmap: [Float], size: [Float], offset: [Float], landmarks: [Float], h: Int, w: Int, stride: Double = 4) -> [Candidate] {
        let n = h * w
        return peaks(heatmap, classes: 1, h: h, w: w, k: 300, threshold: 0.05).map { p in
            let i = p.y * w + p.x
            let cx = (Double(p.x) + Double(offset[i])) * stride, cy = (Double(p.y) + Double(offset[n + i])) * stride
            let bw = Double.exp(Double(size[i])) * stride, bh = Double.exp(Double(size[n + i])) * stride
            let points = (0..<5).map { j in
                (cx + Double(landmarks[(2 * j) * n + i]) * bw, cy + Double(landmarks[(2 * j + 1) * n + i]) * bh)
            }
            return Candidate(label: 0, confidence: p.p, x0: cx - bw / 2, y0: cy - bh / 2, x1: cx + bw / 2, y1: cy + bh / 2,
                             landmarks: points)
        }
    }

    static func iou(_ a: Candidate, _ b: Candidate) -> Double {
        let inter = Candidate(label: 0, confidence: 0, x0: max(a.x0, b.x0), y0: max(a.y0, b.y0),
                              x1: min(a.x1, b.x1), y1: min(a.y1, b.y1)).area
        let union = a.area + b.area - inter
        return union > 0 ? inter / union : 0
    }

    /// How much of `a` lies inside `b`.
    static func inside(_ a: Candidate, _ b: Candidate) -> Double {
        let inter = Candidate(label: 0, confidence: 0, x0: max(a.x0, b.x0), y0: max(a.y0, b.y0),
                              x1: min(a.x1, b.x1), y1: min(a.y1, b.y1)).area
        return a.area > 0 ? inter / a.area : 0
    }

    /// Greedy NMS per label; with `contain`, also drops a weaker box lying mostly
    /// inside a kept box whose confidence it does not reach half of (the same
    /// object seen twice).
    static func nms(_ boxes: [Candidate], iou t: Double, contain: Double? = nil, ratio: Double = 0.5) -> [Candidate] {
        var keep: [Candidate] = []
        for d in boxes.sorted(by: { $0.confidence > $1.confidence }) {
            let suppressed = keep.contains { k in
                k.label == d.label && (iou(k, d) >= t
                    || (contain.map { inside(d, k) >= $0 } ?? false) && d.confidence < ratio * k.confidence)
            }
            if !suppressed { keep.append(d) }
        }
        return keep
    }
}
