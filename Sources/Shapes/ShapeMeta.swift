import JSON

/// The model's sidecar file, `shapes_meta.json`, with the classifier's class
/// order, the reject classes, the input length, and the calibrated gates for
/// each kind. Every platform downloads the file with the model, so each
/// platform uses the values the model was exported with.
struct ShapeMeta: Sendable {
    /// One entry per classifier output. The entry is `nil` for a class this SDK
    /// doesn't know, from a model newer than the SDK, and Shapes rejects that class.
    let classes: [Shape.Kind?]
    /// Classifier outputs Shapes always rejects (`none`).
    let rejects: Set<Int>
    /// Points per resampled stroke (the graph's input length).
    let pointCount: Int
    /// The gates for each kind.
    let gates: [Shape.Kind: Gate]
    /// The largest deviation over chord length for which a connector is straight.
    let straightTolerance: Double

    struct Gate: Sendable {
        var conf: Double = 0
        var resid: Double = .infinity
    }

    init(json: String) throws {
        let raw = try JSONDecoder().decode(Raw.self, from: json)
        classes = raw.classes.map { Shape.Kind(rawValue: $0) }
        rejects = Set(raw.classes.indices.filter { (raw.rejectClasses ?? ["none"]).contains(raw.classes[$0]) })
        pointCount = raw.pointCount
        var gates: [Shape.Kind: Gate] = [:]
        for (name, g) in raw.gates {
            guard let kind = Shape.Kind(rawValue: name) else { continue }
            gates[kind] = Gate(conf: g.conf ?? 0, resid: g.resid ?? .infinity)
        }
        self.gates = gates
        straightTolerance = raw.fit?.straightTolerance ?? 0.06
    }

    private struct Raw: Decodable {
        let classes: [String]
        let rejectClasses: [String]?
        let pointCount: Int
        let gates: [String: RawGate]
        let fit: RawFit?

        enum CodingKeys: String, CodingKey {
            case classes, gates, fit
            case rejectClasses = "reject_classes"
            case pointCount = "n_points"
        }
    }

    private struct RawGate: Decodable {
        let conf: Double?
        let resid: Double?
    }

    private struct RawFit: Decodable {
        let straightTolerance: Double?

        enum CodingKeys: String, CodingKey {
            case straightTolerance = "straight_tolerance"
        }
    }
}
