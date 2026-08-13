// This model's catalog declaration: coordinates, file names, and which of them
// each platform ships. The shared behaviour (distribution, resolve, availability)
// comes from `ModelDeclaration` in the catalog's shared half.

import DesertAnt

/// The emo model: on-device emoji suggestion.
public enum EmoModel: ModelDeclaration {
    public static let id = "emo"
    public static let product = "Emo"
    public static let revision = "v0.7.0"
    /// Matches packages/emo-node/package.json and packages/emo-kotlin/build.gradle.kts
    /// (ModelCatalogTests enforces it).
    public static let sdkVersion = "1.1.0"
    public static let summary = "Multilingual on-device emoji suggestion."

    /// Labels plus the featurizer/tokenizer constants.
    public static let meta = "emo_meta.json"
    /// Pruned-unigram semantic tokenizer.
    public static let tokenizer = "emo_tokenizer.bin"
    /// LiteRT export: Android/Linux/Windows + wasm.
    public static let tflite = "emo.tflite"
    /// Core ML export (a directory on the Hub): Apple.
    public static let coreML = "emo.mlmodelc"

    /// Sidecars every platform needs alongside the artifact.
    public static let sidecars = [meta, tokenizer]

    public static let files: [ModelPlatform: [String]] = [
        .apple: [coreML + "/"] + sidecars,
        .android: [tflite] + sidecars,
        .linux: [tflite] + sidecars,
        .windows: [tflite] + sidecars,
        .web: [tflite] + sidecars,
    ]

    /// Both exports use the same fixed n-gram/semantic window with a `sem_mask`,
    /// so there is no per-artifact tensor shaping to track.
    public static func artifact(for platform: ModelPlatform) -> String {
        platform == .apple ? coreML : tflite
    }
}
