import DesertAnt
import RealModule

/// Something Eye can say about a photo or a face: what it is (`.screenshot`,
/// `.selfie`, `.receipt`), what is in it (`.dog`, `.beach`, 560 scenes), how
/// it came out (`.blurry`, `.eyesClosed`, `.accidental`), who is in it
/// (`.groupShot`, `.portrait`, `.everyoneSmiling`) and whether it is
/// sensitive (`.sensitive`, `.weapon`).
///
/// Every tag has a confidence in `0...1` where 0.5 is the recommended cutoff
/// and 0.9 a strict one, the same for every tag. The constants (`Tag.dog`)
/// are the tags of the model this SDK pins; a newer model may add more, which
/// `Tag("name")` reaches.
public struct Tag: RawRepresentable, Hashable, Sendable, Codable, Comparable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    /// The tag's id, `snake_case` (`"group_shot"`).
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ id: String) { self.rawValue = id }
    public init(stringLiteral id: String) { self.rawValue = id }

    public var description: String { rawValue }
    public static func < (a: Tag, b: Tag) -> Bool { a.rawValue < b.rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// How sure a tag must be: the cutoff on its confidence.
public enum Level: Sendable, Hashable {
    /// 0.5: the balance of precision and recall Eye recommends.
    case recommended
    /// 0.9: high precision; fewer photos, more surely right.
    case strict

    public var cutoff: Double {
        switch self {
        case .recommended: 0.5
        case .strict: 0.9
        }
    }
}

/// How a photo scores against other photos, each a percentile in `0...1`
/// (0.5 is the median photo of the calibration set).
public struct Scores: Sendable, Hashable, Codable {
    /// How good the photo is as a photograph.
    public let aesthetic: Double
    /// How likely people are to keep a photo like this.
    public let keeper: Double
    /// How well it would work as a cover or thumbnail.
    public let cover: Double
}

/// One face in the photo, with its tags.
public struct Face: Sendable, Codable {
    public let box: Box
    /// How sure the detector is that this is a face, `0...1`.
    public let detectionConfidence: Double
    /// Left eye, right eye, nose tip, left and right mouth corners.
    public let landmarks: [Point]
    public let pose: Pose
    /// Overall quality of the face in this photo, `0...1`.
    public let quality: Double
    /// Every face tag with its confidence: `.eyesClosed`, `.smiling`,
    /// `.lookingAtCamera`, `.lookingAway`, `.happy`, `.surprised`.
    public let confidences: [Tag: Double]

    /// The face's confidence for `tag`, `nil` if Eye has no such face tag.
    public func confidence(_ tag: Tag) -> Double? { confidences[tag] }

    /// Whether `tag` reaches `level`.
    public func has(_ tag: Tag, _ level: Level = .recommended) -> Bool { (confidences[tag] ?? 0) >= level.cutoff }

    enum CodingKeys: String, CodingKey {
        case box, detectionConfidence = "detection_confidence", landmarks, pose, quality, confidences = "tags"
    }

    init(box: Box, detectionConfidence: Double, landmarks: [Point], pose: Pose, quality: Double, confidences: [Tag: Double]) {
        self.box = box
        self.detectionConfidence = detectionConfidence
        self.landmarks = landmarks
        self.pose = pose
        self.quality = quality
        self.confidences = confidences
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        box = try c.decode(Box.self, forKey: .box)
        detectionConfidence = try c.decode(Double.self, forKey: .detectionConfidence)
        landmarks = try c.decode([Point].self, forKey: .landmarks)
        pose = try c.decode(Pose.self, forKey: .pose)
        quality = try c.decode(Double.self, forKey: .quality)
        confidences = tagged(try c.decode([String: Double].self, forKey: .confidences))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(box, forKey: .box)
        try c.encode(detectionConfidence, forKey: .detectionConfidence)
        try c.encode(landmarks, forKey: .landmarks)
        try c.encode(pose, forKey: .pose)
        try c.encode(quality, forKey: .quality)
        try c.encode(untagged(confidences), forKey: .confidences)
    }
}

/// What Eye found in one photo: tags with confidences, scores, people, pets,
/// faces, a crop, a rotation fix and an embedding.
///
/// Filter with ``has(_:_:)``, rank with ``confidence(_:)`` or ``scores``.
/// Everything except ``details`` is `Codable` and stable across platforms:
/// store analyses (JSON), and filter or group them later without the model.
public struct Analysis: Sendable, Codable {
    /// The model that produced this analysis (`"eye@v1.0.0"`).
    public let model: String
    /// The analyzed image's size in pixels.
    public let width: Int
    public let height: Int
    /// Every tag computed with its confidence (`0...1`, 0.5 the recommended
    /// cutoff). A tag whose part was not computed is absent.
    public let confidences: [Tag: Double]
    /// The most likely photo type: `.photo`, `.selfie`, `.screenshot`,
    /// `.document`, `.receipt`, ... (needs ``Parts/photo``).
    public let kind: Tag?
    /// Percentile scores (needs ``Parts/photo``).
    public let scores: Scores?
    /// How far the photo is turned clockwise from upright (90, 180 or 270), so
    /// turning it back counterclockwise by this much makes it upright. `nil` when
    /// it is upright or Eye is unsure (needs ``Parts/photo``).
    public let rotation: Int?
    /// 512 numbers, unit length; see ``similarity(to:)`` (needs ``Parts/photo``).
    public let embedding: [Float]?
    /// People and pets (`"cat"`, `"dog"`) with boxes (needs ``Parts/layout``).
    public let people: [Detection]?
    public let pets: [Detection]?
    /// Faces, most confident first (needs ``Parts/faces``).
    public let faces: [Face]?
    /// The best crops, best first (needs ``Parts/layout``); see ``bestCrop(aspect:)``.
    public let crops: [Crop]?
    /// The model's raw outputs. `nil` for an analysis decoded from JSON.
    public let details: Details?
    let duplicates: DuplicateRule?

    /// The photo's confidence for `tag`, `nil` when it was not computed.
    public func confidence(_ tag: Tag) -> Double? { confidences[tag] }

    /// Whether `tag` reaches `level` (0.5 recommended, 0.9 strict).
    public func has(_ tag: Tag, _ level: Level = .recommended) -> Bool { (confidences[tag] ?? 0) >= level.cutoff }

    /// The tags at or above `level`, most confident first.
    public func tags(_ level: Level = .recommended) -> [Tag] {
        confidences.filter { $0.value >= level.cutoff }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    /// The best crop with this width-to-height ratio (1 for square, 16 / 9 for
    /// a wide banner), in `0...1` of the image. `nil` without ``Parts/layout``.
    public func bestCrop(aspect: Double) -> Box? {
        guard let crops, let best = crops.first, aspect > 0 else { return nil }
        let px = { (b: Box) in b.width * Double(width) / max(b.height * Double(height), 1e-9) }
        if let fit = crops.first(where: { abs(Double.log(px($0.box) / aspect)) <= Double.log(1.1) }) { return fit.box }
        // No candidate this shape: the best crop widened or narrowed about its centre, kept inside the image.
        var w = best.box.width, h = best.box.height
        let target = aspect * Double(height) / Double(width)
        if w / h > target { w = h * target } else { h = w / target }
        if w > 1 { h /= w; w = 1 }
        if h > 1 { w /= h; h = 1 }
        let cx = min(max((best.box.x0 + best.box.x1) / 2, w / 2), 1 - w / 2)
        let cy = min(max((best.box.y0 + best.box.y1) / 2, h / 2), 1 - h / 2)
        return Box(x0: cx - w / 2, y0: cy - h / 2, x1: cx + w / 2, y1: cy + h / 2)
    }

    /// Cosine similarity of the two embeddings, `-1...1`; near-duplicates are
    /// above about 0.9. `nil` if either has no embedding.
    public func similarity(to other: Analysis) -> Double? {
        guard let a = embedding, let b = other.embedding, a.count == b.count else { return nil }
        var s: Float = 0
        for i in a.indices { s += a[i] * b[i] }
        return Double(s)
    }

    enum CodingKeys: String, CodingKey {
        case model, width, height, confidences = "tags", kind, scores, rotation, embedding, people, pets, faces, crops, duplicates
    }

    init(model: String, width: Int, height: Int, confidences: [Tag: Double], kind: Tag?, scores: Scores?, rotation: Int?,
         embedding: [Float]?, people: [Detection]?, pets: [Detection]?, faces: [Face]?, crops: [Crop]?, details: Details?,
         duplicates: DuplicateRule?) {
        self.model = model
        self.width = width
        self.height = height
        self.confidences = confidences
        self.kind = kind
        self.scores = scores
        self.rotation = rotation
        self.embedding = embedding
        self.people = people
        self.pets = pets
        self.faces = faces
        self.crops = crops
        self.details = details
        self.duplicates = duplicates
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        confidences = tagged(try c.decode([String: Double].self, forKey: .confidences))
        kind = try c.decodeIfPresent(Tag.self, forKey: .kind)
        scores = try c.decodeIfPresent(Scores.self, forKey: .scores)
        rotation = try c.decodeIfPresent(Int.self, forKey: .rotation)
        embedding = try c.decodeIfPresent([Float].self, forKey: .embedding)
        people = try c.decodeIfPresent([Detection].self, forKey: .people)
        pets = try c.decodeIfPresent([Detection].self, forKey: .pets)
        faces = try c.decodeIfPresent([Face].self, forKey: .faces)
        crops = try c.decodeIfPresent([Crop].self, forKey: .crops)
        duplicates = try c.decodeIfPresent(DuplicateRule.self, forKey: .duplicates)
        details = nil
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(untagged(confidences), forKey: .confidences)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(scores, forKey: .scores)
        try c.encodeIfPresent(rotation, forKey: .rotation)
        try c.encodeIfPresent(embedding, forKey: .embedding)
        try c.encodeIfPresent(people, forKey: .people)
        try c.encodeIfPresent(pets, forKey: .pets)
        try c.encodeIfPresent(faces, forKey: .faces)
        try c.encodeIfPresent(crops, forKey: .crops)
        try c.encodeIfPresent(duplicates, forKey: .duplicates)
    }
}

/// The model's near-duplicate rule, carried by each analysis so stored ones
/// group without the model (eye_meta.json `tags.duplicates`).
struct DuplicateRule: Sendable, Hashable, Codable {
    let similarity: Double
    let windowSeconds: Double
    let windowSecondsPeople: Double

    enum CodingKeys: String, CodingKey {
        case similarity, windowSeconds = "window_seconds", windowSecondsPeople = "window_seconds_people"
    }
}

func tagged(_ d: [String: Double]) -> [Tag: Double] {
    Dictionary(uniqueKeysWithValues: d.map { (Tag($0.key), $0.value) })
}

func untagged(_ d: [Tag: Double]) -> [String: Double] {
    Dictionary(uniqueKeysWithValues: d.map { ($0.key.rawValue, $0.value) })
}
