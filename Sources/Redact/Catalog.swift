// This model's catalog declaration: coordinates, file names, and which of them
// each platform ships. The shared behaviour (distribution, resolve, availability)
// comes from `ModelDeclaration` in the catalog's shared half.

import DesertAnt

/// The redact model: multilingual on-device PII detection.
public enum RedactModel: ModelDeclaration {
    public static let id = "redact"
    public static let product = "Redact"
    public static let revision = "v0.4.0"
    /// Matches packages/redact-node/package.json and
    /// packages/redact-kotlin/build.gradle.kts (ModelCatalogTests enforces it).
    public static let sdkVersion = "1.0.0"
    public static let summary = "Multilingual on-device PII detection and redaction."

    /// Compact SentencePiece vocab.
    public static let tokenizer = "redact_tokenizer.bin"
    /// BIOES id -> label map.
    public static let labels = "labels.json"
    /// LiteRT export: Android/Linux/Windows + wasm.
    public static let tflite = "redact.tflite"
    /// Core ML export (a directory on the Hub): Apple.
    public static let coreML = "redact.mlmodelc"

    /// Sidecars every platform needs alongside the artifact.
    public static let sidecars = [tokenizer, labels]

    public static let files: [ModelPlatform: [String]] = [
        .apple: [coreML + "/"] + sidecars,
        .android: [tflite] + sidecars,
        .linux: [tflite] + sidecars,
        .windows: [tflite] + sidecars,
        .web: [tflite] + sidecars,
    ]

    /// Both exports use the same fixed-256, int32, baked-position-ids window, so
    /// there is no per-artifact tensor shaping to track.
    public static func artifact(for platform: ModelPlatform) -> String {
        platform == .apple ? coreML : tflite
    }
}
