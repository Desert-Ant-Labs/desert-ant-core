import JSON
import RealModule

/// eye_meta.json's `tags` section (ml-eye `ml_eye/tags.py`, which this evaluates
/// exactly as its `evaluate` does): model tags as curves from an output to a
/// confidence, derived tags as rules over signals.
struct TagSpec: Sendable, Decodable {
    struct ModelTag: Sendable, Decodable {
        let id: String
        let output: String
        let index: Int?
        let indices: [Int]?
        let turned: Bool?
        let curve: [[Double]]
    }

    struct RuleTag: Sendable, Decodable {
        let id: String
        let rule: Rule
    }

    struct FaceFilter: Sendable, Decodable {
        let minConfidence: Double
        let minSize: Double
        let minReal: Double
        let prominentSize: Double

        enum CodingKeys: String, CodingKey {
            case minConfidence = "min_confidence", minSize = "min_size", minReal = "min_real", prominentSize = "prominent_size"
        }
    }

    struct Score: Sendable, Decodable {
        let median: Double
        let scale: Double
    }

    let model: [ModelTag]
    let photo: [RuleTag]
    let face: [RuleTag]
    let faces: FaceFilter
    let scores: [String: Score]
    let duplicates: DuplicateRule

    /// A threshold test: 0.5 at `value`, 0.9 at `strict`, linear and clamped;
    /// without `strict`, 0 or 1.
    struct Threshold: Sendable {
        let above: Bool
        let value: Double
        let strict: Double?

        func confidence(_ x: Double?) -> Double {
            guard let x else { return 0 }
            guard let strict else { return (above ? x >= value : x <= value) ? 1 : 0 }
            let c = 0.5 + 0.4 * (above ? x - value : value - x) / abs(strict - value)
            return min(max(c, 0), 1)
        }
    }

    indirect enum Rule: Sendable, Decodable {
        case all([Rule]), any([Rule]), not(Rule), tag(String)
        case anyFace(Rule, prominent: Bool), allFaces(Rule, prominent: Bool)
        case count(prominent: Bool, Threshold), signal(String, Threshold)

        enum Key: String, CodingKey {
            case all, any, not, tag, anyFace = "any_face", allFaces = "all_faces", scope, count, signal, above, below, strict
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            func threshold() throws -> Threshold {
                let above = try c.decodeIfPresent(Double.self, forKey: .above)
                guard let value = try above ?? c.decodeIfPresent(Double.self, forKey: .below) else { throw EyeError.resourceMissing }
                return Threshold(above: above != nil, value: value, strict: try c.decodeIfPresent(Double.self, forKey: .strict))
            }
            let prominent = try c.decodeIfPresent(String.self, forKey: .scope) == "prominent_faces"
            if let r = try c.decodeIfPresent([Rule].self, forKey: .all) { self = .all(r) }
            else if let r = try c.decodeIfPresent([Rule].self, forKey: .any) { self = .any(r) }
            else if let r = try c.decodeIfPresent(Rule.self, forKey: .not) { self = .not(r) }
            else if let t = try c.decodeIfPresent(String.self, forKey: .tag) { self = .tag(t) }
            else if let r = try c.decodeIfPresent(Rule.self, forKey: .anyFace) { self = .anyFace(r, prominent: prominent) }
            else if let r = try c.decodeIfPresent(Rule.self, forKey: .allFaces) { self = .allFaces(r, prominent: prominent) }
            else if let n = try c.decodeIfPresent(String.self, forKey: .count) { self = .count(prominent: n == "prominent_faces", try threshold()) }
            else if let s = try c.decodeIfPresent(String.self, forKey: .signal) { self = .signal(s, try threshold()) }
            else { throw EyeError.resourceMissing }
        }
    }

    /// A rule needs a part that was not computed.
    struct Unknown: Error {}

    /// A face as photo-level rules see it.
    struct CountedFace {
        let signals: [String: Double]
        let tags: [String: Double]
        let prominent: Bool
        let side: Double
    }

    func confidence(_ rule: Rule, signals: [String: Double?], tags: [String: Double], faces: [CountedFace]?) throws -> Double {
        switch rule {
        case .all(let rs): return try rs.map { try confidence($0, signals: signals, tags: tags, faces: faces) }.min() ?? 0
        case .any(let rs): return try rs.map { try confidence($0, signals: signals, tags: tags, faces: faces) }.max() ?? 0
        case .not(let r): return 1 - (try confidence(r, signals: signals, tags: tags, faces: faces))
        case .tag(let t):
            guard let v = tags[t] else { throw Unknown() }
            return v
        case .anyFace(let r, let prominent), .allFaces(let r, let prominent):
            guard let faces else { throw Unknown() }
            let vals = try faces.filter { !prominent || $0.prominent }.map {
                try confidence(r, signals: $0.signals.mapValues { Optional($0) }, tags: $0.tags, faces: nil)
            }
            guard !vals.isEmpty else { return 0 }
            if case .anyFace = rule { return vals.max()! }
            return vals.min()!
        case .count(let prominent, let t):
            guard let faces else { throw Unknown() }
            return t.confidence(Double(faces.filter { !prominent || $0.prominent }.count))
        case .signal(let name, let t):
            guard let v = signals[name] else { throw Unknown() }
            return t.confidence(v)
        }
    }

    static func interp(_ x: Double, _ knots: [[Double]]) -> Double {
        guard let first = knots.first, let last = knots.last else { return x }
        if x <= first[0] { return first[1] }
        for (a, b) in zip(knots, knots.dropFirst()) where x <= b[0] {
            return b[0] == a[0] ? b[1] : a[1] + (b[1] - a[1]) * (x - a[0]) / (b[0] - a[0])
        }
        return last[1]
    }

    /// A head's probability as its percentile among photos.
    func percentile(_ prob: Double, _ score: Score) -> Double {
        let p = min(max(prob, 1e-6), 1 - 1e-6)
        let z = (Double.log(p / (1 - p)) - score.median) / score.scale
        return 0.5 * (1 + Double.erf(z / 2.0.squareRoot()))
    }

    /// One face's analysis, the signals face rules read.
    struct FaceInput {
        let box: Box
        let confidence: Double
        let isReal: Double
        let signals: [String: Double]
    }

    /// Every tag of a photo, and each face's.
    func evaluate(outputs: [String: [Float]]?, sharpness: Double?, faces: [FaceInput]?, width: Int, height: Int)
        -> (photo: [String: Double], faces: [[String: Double]]?) {
        var tags: [String: Double] = [:]
        if let outputs {
            for t in model {
                guard let o = outputs[t.output] else { continue }
                let x: Double
                if let idx = t.indices {
                    guard idx.allSatisfy({ $0 < o.count }) else { continue }
                    x = idx.reduce(0) { $0 + Double(o[$1]) }
                } else if t.turned == true { x = Double(o.dropFirst().max() ?? 0) }
                else if let i = t.index, i < o.count { x = Double(o[i]) }
                else { continue }
                tags[t.id] = Self.interp(x, t.curve)
            }
        }
        var faceTags: [[String: Double]]?
        var counted: [CountedFace]?
        if let faces {
            faceTags = []
            counted = []
            let W = Double(width), H = Double(height), long = max(W, H)
            for f in faces {
                var ft: [String: Double] = [:]
                for t in face {
                    ft[t.id] = (try? confidence(t.rule, signals: f.signals.mapValues { Optional($0) }, tags: ft, faces: nil)) ?? 0
                }
                faceTags!.append(ft)
                let side = max(f.box.width * W, f.box.height * H) / long
                if f.confidence >= self.faces.minConfidence && side >= self.faces.minSize && f.isReal >= self.faces.minReal {
                    counted!.append(CountedFace(signals: f.signals, tags: ft, prominent: side >= self.faces.prominentSize, side: side))
                }
            }
        }
        var signals: [String: Double?] = [:]
        if let outputs {
            if let focus = outputs["focus"], focus.count > 3 { signals["bokeh"] = Double(focus[3]) }
            if let peak = outputs["peak_logits"], peak.count > 1 { signals["peak"] = 1 / (1 + Double.exp(-Double(peak[1]))) }
        }
        if let sharpness { signals["sharpness"] = sharpness }
        if let counted {
            let prom = counted.filter(\.prominent)
            let w = prom.reduce(0) { $0 + $1.side }
            signals["faces_quality"] = prom.isEmpty ? .some(nil) : prom.reduce(0) { $0 + ($1.signals["quality"] ?? 0) * $1.side } / w
        }
        for t in photo {
            if let v = try? confidence(t.rule, signals: signals, tags: tags, faces: counted) { tags[t.id] = v }
        }
        return (tags, faceTags)
    }
}
