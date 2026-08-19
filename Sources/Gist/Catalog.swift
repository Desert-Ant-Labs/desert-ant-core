// This model's catalog declaration: coordinates, file names, and which of them
// each platform ships. The shared behaviour (distribution, resolve, availability)
// comes from `ModelDeclaration` in the catalog's shared half.

import DesertAnt

/// The gist model: on-device content topic tagging.
public enum GistModel: ModelDeclaration {
    public static let id = "gist"
    public static let product = "Gist"
    public static let revision = "v2.2.0"
    /// Matches packages/gist-node/package.json and packages/gist-kotlin/build.gradle.kts
    /// (ModelCatalogTests enforces it).
    public static let sdkVersion = "1.2.0"
    public static let summary = "Multilingual on-device content topic tagging across a 36-topic taxonomy."

    /// The variant this declaration describes: the SDK default. The repo also
    /// publishes the English-only build under `en/`, which a caller selects per
    /// instance (`Gist(variant:)`) and which downloads through ``GistVariant``
    /// rather than through this manifest - the catalog entry stays one model's
    /// default artifact, which is what tooling and the shared fixtures expect.
    public static let variant = GistVariant.default

    /// Pruned-unigram semantic tokenizer.
    public static let tokenizer = variant.tokenizer
    /// Quantized potion embedding table, plus the JSON describing its shape.
    public static let embedding = variant.embedding
    public static let embeddingMeta = variant.embeddingMeta
    /// Featurizer/head constants (n-gram buckets, threshold, dimensions).
    public static let config = variant.config
    /// Slug -> display name for the 36 topics.
    public static let taxonomy = variant.taxonomy
    /// LiteRT export: Android/Linux/Windows + wasm.
    public static let tflite = variant.tflite
    /// Core ML export (a directory on the Hub): Apple.
    public static let coreML = variant.coreML

    /// Sidecars every platform needs alongside the artifact.
    public static let sidecars = variant.sidecars

    public static let files: [ModelPlatform: [String]] = variant.files

    public static func artifact(for platform: ModelPlatform) -> String {
        variant.artifact(for: platform)
    }
}
