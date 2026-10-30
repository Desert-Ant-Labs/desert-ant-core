import DesertAnt

/// The eye model: on-device photo understanding.
///
/// One artifact per platform carries every task as a named function (Core ML)
/// or signature (LiteRT), the same names on both: `photo_peak` (the centre crop:
/// embedding, type, scenes, quality scores, peak moment), `spatial` (the whole
/// frame: attention map, people and pet boxes, shot type, crop scores),
/// `faces_detect` and `faces_analyze`, and one `sharp_<aspect>` per input shape.
/// `eye_meta.json` beside it names every output index and holds the decoding
/// constants.
public enum EyeModel: ModelDeclaration {
    public static let id = "eye"
    public static let product = "Eye"
    public static let revision = "v1.0.0"
    public static let sdkVersion = "4.2.3"
    public static let summary = "On-device photo understanding: scenes, quality, faces, people, pets, crops and sharpness."
    /// `eye.mlmodelc` is a multifunction package, an iOS 18 feature.
    public static let osFloor = OSFloor.multifunction

    /// Output names and decoding constants.
    public static let meta = "eye_meta.json"
    /// Core ML export (a directory on the Hub, 48 MB, every function on the Neural Engine): Apple.
    public static let coreML = "eye.mlmodelc"
    /// LiteRT export (66 MB, int8 weights, one signature per function): Android, Linux, Windows, wasm.
    public static let tflite = "eye.tflite"

    public static let files: [ModelPlatform: [String]] = [
        .apple: [coreML + "/", meta],
        .android: [tflite, meta],
        .linux: [tflite, meta],
        .windows: [tflite, meta],
        .web: [tflite, meta],
    ]

    public static func artifact(for platform: ModelPlatform) -> String {
        platform == .apple ? coreML : tflite
    }

    /// Sharpness inputs, `(height, width)`: a photo goes to the closest aspect.
    static let sharpShapes: [(aspect: String, height: Int, width: Int)] = [
        ("4x3", 576, 768), ("3x4", 768, 576), ("16x9", 432, 768), ("9x16", 768, 432),
    ]

    /// Every function the SDK runs: Core ML function and LiteRT signature names.
    public static let functions = ["photo_peak", "spatial", "faces_detect", "faces_analyze"]
        + sharpShapes.map { "sharp_\($0.aspect)" }
}
