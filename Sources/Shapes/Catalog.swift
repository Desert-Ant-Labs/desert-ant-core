import DesertAnt

/// The shapes model: on-device single-stroke shape recognition.
public enum ShapesModel: ModelDeclaration {
    public static let id = "shapes"
    public static let product = "Shapes"
    public static let revision = "v1.0.0"
    public static let sdkVersion = "4.1.0"
    public static let summary = "On-device single-stroke shape recognition."

    /// Class order, input length, and the calibrated gates.
    public static let meta = "shapes_meta.json"
    /// LiteRT export: Android/Linux/Windows + wasm.
    public static let tflite = "shapes.tflite"
    /// Core ML export (a directory on the Hub): Apple.
    public static let coreML = "shapes.mlmodelc"

    /// Sidecars every platform needs alongside the artifact.
    public static let sidecars = [meta]

    public static let files: [ModelPlatform: [String]] = [
        .apple: [coreML + "/"] + sidecars,
        .android: [tflite] + sidecars,
        .linux: [tflite] + sidecars,
        .windows: [tflite] + sidecars,
        .web: [tflite] + sidecars,
    ]

    /// Both exports have the same tensors: input `points` [1, 128, 2] (the
    /// stroke as `Preprocess` resamples and normalizes it), outputs `probs`
    /// [1, 13] and `head` [1, 128] (the arrowhead probability of each point).
    /// The SDK needs no per-artifact tensor shaping.
    public static func artifact(for platform: ModelPlatform) -> String {
        platform == .apple ? coreML : tflite
    }
}
