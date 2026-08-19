// This model's catalog declaration: coordinates, file names, and which of them
// each platform ships. The shared behaviour (distribution, resolve, availability)
// comes from `ModelDeclaration` in the catalog's shared half.

import DesertAnt

/// The shapes model: on-device single-stroke shape recognition.
public enum ShapesModel: ModelDeclaration {
    public static let id = "shapes"
    public static let product = "Shapes"
    public static let revision = "v0.3.0"
    /// Matches packages/shapes-node/package.json and
    /// packages/shapes-kotlin/build.gradle.kts (ModelCatalogTests enforces it).
    public static let sdkVersion = "3.0.0"
    public static let summary = "On-device single-stroke shape recognition."

    /// Class order, calibrated gates, and the frozen preprocessing constants.
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

    /// Both exports share one graph: a fixed 256-length window of
    /// `[distance, cos, sin]` features plus a 1/0 validity mask, so there is no
    /// per-artifact tensor shaping to track.
    public static func artifact(for platform: ModelPlatform) -> String {
        platform == .apple ? coreML : tflite
    }
}
