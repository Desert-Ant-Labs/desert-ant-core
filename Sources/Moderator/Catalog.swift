// This model's catalog declaration: coordinates, file names, and which of them
// each platform ships. The shared behaviour (distribution, resolve, availability)
// comes from `ModelDeclaration` in the catalog's shared half.

import DesertAnt

/// The moderator model: on-device NSFW image detection.
public enum ModeratorModel: ModelDeclaration {
    public static let id = "moderator"
    public static let product = "Moderator"
    /// The first public release. The Core ML and LiteRT files share one
    /// signature (see `artifact(for:)`).
    public static let revision = "v1.0.0"
    /// Matches packages/moderator-node/package.json and
    /// packages/moderator-kotlin/build.gradle.kts (ModelCatalogTests enforces it).
    public static let sdkVersion = "3.5.0"
    public static let summary = "On-device NSFW image detection, trained only on licensed and synthetic data."

    /// LiteRT export (int8, ~9.2 MB): Android/Linux/Windows + wasm.
    public static let tflite = "moderator.tflite"
    /// Core ML export (a directory on the Hub, int8, ~9.7 MB), every op on the
    /// Neural Engine: Apple.
    public static let coreML = "moderator.mlmodelc"

    public static let files: [ModelPlatform: [String]] = [
        .apple: [coreML + "/"],
        .android: [tflite],
        .linux: [tflite],
        .windows: [tflite],
        .web: [tflite],
    ]

    /// Both exports share one signature: `image` `[1, 384, 384, 3]` RGB pixels
    /// in `0...255`, and `scores` `[1, 5]`.
    public static func artifact(for platform: ModelPlatform) -> String {
        platform == .apple ? coreML : tflite
    }
}
