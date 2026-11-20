import JSON

/// The model's sidecar file, `shapes_meta.json`: the kinds in output order, the
/// kinds Shapes rejects, the input size, where each kind's template numbers sit
/// in the `numbers` output and how they are coded, and the residual gates. Every
/// build has its copy beside it, so each platform reads the values its build was
/// exported with.
struct ShapeMeta: Sendable {
    /// The model's kinds in output order, by name (`none` included).
    let kinds: [String]
    /// Output indices Shapes always rejects (`none`).
    let rejects: Set<Int>
    /// Points per drawing (the graph's input length).
    let pointCount: Int
    /// Strokes kept per drawing, in drawing order.
    let maxStrokes: Int
    /// The input's values per point, by name, in order: x, y, dx, dy, start,
    /// and log1p_dt for a model that reads time.
    let channels: [String]
    /// Channels the model was trained with at 0 (a time channel it does not
    /// read): fed 0 for every point.
    let zeroChannels: Set<String>
    /// Width of the `numbers` output.
    let numbersWidth: Int
    /// Each kind's slice of `numbers`, by kind name.
    let numbers: [String: KindNumbers]
    /// The largest residual at which each kind snaps, by kind name; a kind with
    /// no gate always snaps.
    let residGates: [String: Double]
    /// The most of a finished drawing's fitted outline that may lie far from
    /// the ink, by kind name, where the release tunes it; other kinds take
    /// `Model.maximumUndrawn`.
    let undrawnLimits: [String: Double]

    struct KindNumbers: Sendable {
        /// Where the kind's outputs start in `numbers`.
        let offset: Int
        /// The kind's outputs: its numbers, an angle as `cos` and `sin`.
        let outputs: [String]
        /// The template numbers the outputs decode to, in order.
        let names: [String]
        /// How many times a turn brings the template back onto itself: an angle
        /// comes out as the cos and sin of `symmetry` times the angle.
        let symmetry: Int?
        /// A zigzag's teeth come out divided by this.
        let teethScale: Double?
    }

    init(json: String) throws {
        let raw = try JSONDecoder().decode(Raw.self, from: json)
        kinds = raw.kinds
        rejects = Set(raw.kinds.indices.filter { raw.rejectKinds.contains(raw.kinds[$0]) })
        pointCount = raw.pointCount
        maxStrokes = raw.maxStrokes
        channels = raw.input?.x.channels ?? Ink.channels
        zeroChannels = Set(raw.input?.x.zeroChannels ?? [])
        numbersWidth = raw.outputs.numbers.last ?? 0
        numbers = raw.numbers.kinds.mapValues {
            KindNumbers(offset: $0.offset, outputs: $0.outputs, names: $0.numbers,
                        symmetry: $0.symmetry, teethScale: $0.teethScale)
        }
        residGates = raw.residGates
        undrawnLimits = raw.undrawnLimits ?? [:]
    }

    private struct Raw: Decodable {
        let kinds: [String]
        let rejectKinds: [String]
        let pointCount: Int
        let maxStrokes: Int
        let input: RawInput?
        let outputs: RawOutputs
        let numbers: RawNumbers
        let residGates: [String: Double]
        let undrawnLimits: [String: Double]?

        enum CodingKeys: String, CodingKey {
            case kinds, input, outputs, numbers
            case rejectKinds = "reject_kinds"
            case pointCount = "n_points"
            case maxStrokes = "max_strokes"
            case residGates = "resid_gates"
            case undrawnLimits = "undrawn_limits"
        }
    }

    private struct RawInput: Decodable {
        let x: RawX
    }

    private struct RawX: Decodable {
        let channels: [String]?
        let zeroChannels: [String]?

        enum CodingKeys: String, CodingKey {
            case channels
            case zeroChannels = "zero_channels"
        }
    }

    private struct RawOutputs: Decodable {
        let numbers: [Int]
    }

    private struct RawNumbers: Decodable {
        let kinds: [String: RawKind]
    }

    private struct RawKind: Decodable {
        let offset: Int
        let outputs: [String]
        let numbers: [String]
        let symmetry: Int?
        let teethScale: Double?

        enum CodingKeys: String, CodingKey {
            case offset, outputs, numbers, symmetry
            case teethScale = "teeth_scale"
        }
    }
}
