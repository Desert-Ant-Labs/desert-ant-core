import JSON

/// The model sidecar (`shapes_meta.json`): the class order the classifier emits,
/// the calibrated per-class confidence/residual gates, and the frozen
/// preprocessing constants. Shipped next to every artifact so the runtime uses
/// exactly the values the model was trained and exported with, on every platform.
struct ShapeMeta: Sendable {
    /// One entry per classifier output index. `nil` marks a reject class (e.g.
    /// "none") that is never accepted as a shape.
    let classOrder: [ShapeKind?]
    /// Per-class acceptance gate.
    let gates: [ShapeKind: Gate]
    /// The preprocessing configuration the model expects.
    let config: PreprocessConfig

    struct Gate: Sendable {
        let conf: Float
        let resid: Float
    }

    /// Parse the JSON sidecar with the platform's native decoder (Codable).
    init(json: String) throws {
        let raw = try JSONDecoder().decode(Raw.self, from: json)
        classOrder = raw.classes.map { ShapeKind(rawValue: $0) }
        var gates: [ShapeKind: Gate] = [:]
        for (name, value) in raw.gates {
            if let kind = ShapeKind(rawValue: name) {
                gates[kind] = Gate(conf: Float(value.conf), resid: Float(value.resid))
            }
        }
        self.gates = gates
        config = PreprocessConfig(
            spacing: raw.preprocess.spacing,
            distMean: raw.preprocess.distMean,
            distStd: raw.preprocess.distStd,
            addCurvature: raw.preprocess.addCurvature)
    }

    private struct Raw: Decodable {
        let classes: [String]
        let gates: [String: RawGate]
        let preprocess: RawPreprocess
    }

    private struct RawGate: Decodable {
        let conf: Double
        let resid: Double
    }

    private struct RawPreprocess: Decodable {
        let spacing: Double
        let distMean: Double
        let distStd: Double
        let addCurvature: Bool

        enum CodingKeys: String, CodingKey {
            case spacing
            case distMean = "dist_mean"
            case distStd = "dist_std"
            case addCurvature = "add_curvature"
        }
    }
}
