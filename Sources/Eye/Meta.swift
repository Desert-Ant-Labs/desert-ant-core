import JSON

/// The model sidecar (`eye_meta.json`): the name behind every output index and
/// the constants the outputs are decoded with, shipped next to every artifact so
/// the SDK reads exactly what the model was exported with.
struct Meta: Sendable {
    let labels: Labels
    /// Crop candidates `[x0, y0, x1, y1]` in `0...1`, the order of `crop_scores`.
    let cropCandidates: [Box]
    let person: BoxDecoding
    let pet: BoxDecoding
    /// Tags: calibrated curves and rules (`tags`).
    let tags: TagSpec

    struct Labels: Sendable, Decodable {
        let type: [String]
        let reject: [String]
        let sensitive: [String]
        let scenes: [String]
        let rotation: [Int]
        let aesthetic: [String]
        let focus: [String]
        let petAttrs: [String]
        let peakLogits: [String]
        let pets: [String]
        let shot: [String]
        let faceBlink: [String]
        let faceMouth: [String]
        let faceExpression: [String]
        let faceOcclusion: [String]
        let faceLighting: [String]

        enum CodingKeys: String, CodingKey {
            case type, reject, sensitive, scenes, rotation, aesthetic, focus, pets, shot
            case petAttrs = "pet_attrs", peakLogits = "peak_logits", faceBlink = "face_blink", faceMouth = "face_mouth"
            case faceExpression = "face_expression", faceOcclusion = "face_occlusion", faceLighting = "face_lighting"
        }
    }

    /// How a box head's detections are kept: NMS, then a confidence threshold.
    struct BoxDecoding: Sendable, Decodable {
        let nmsIoU: Double
        /// Also drop a weaker box lying at least this much inside a kept one.
        let nmsContain: Double?
        let threshold: Double
        /// Pets: confidences are first multiplied by P(scene)^power.
        let sceneGatePower: Double?

        enum CodingKeys: String, CodingKey {
            case nmsIoU = "nms_iou", nmsContain = "nms_contain", threshold, sceneGatePower = "scene_gate_power"
        }
    }

    init(json bytes: [UInt8]) throws {
        let raw = try JSONDecoder().decode(Raw.self, from: bytes)
        labels = raw.labels
        cropCandidates = try raw.cropCandidates.map {
            guard $0.count == 4 else { throw EyeError.resourceMissing }
            return Box(x0: $0[0], y0: $0[1], x1: $0[2], y1: $0[3])
        }
        person = raw.detectionPostprocess.person
        pet = raw.detectionPostprocess.pet
        tags = raw.tags
    }

    private struct Raw: Decodable {
        let labels: Labels
        let cropCandidates: [[Double]]
        let detectionPostprocess: Postprocess
        let tags: TagSpec

        enum CodingKeys: String, CodingKey {
            case labels, cropCandidates = "crop_candidates", detectionPostprocess = "detection_postprocess", tags
        }
    }

    private struct Postprocess: Decodable {
        let person: BoxDecoding
        let pet: BoxDecoding
    }
}
