// This model's catalog declaration: coordinates, file names, and which of them
// each platform ships. The shared behaviour (distribution, resolve, availability)
// comes from `ModelDeclaration` in the catalog's shared half.

import DesertAnt

/// The clear model: on-device speech enhancement (DeepFilterNet3).
public enum ClearModel: ModelDeclaration {
    public static let id = "clear"
    public static let product = "Clear"
    // The Hub repo's `v0.1.0` tag predates the LiteRT export, so pinning it
    // would leave Android/Linux/web with no artifact. Tracks `main` until the
    // next tag carries `clear-studio.tflite`, then becomes that `v`-tag.
    public static let revision = "main"
    /// No published npm/Maven package yet, so nothing cross-checks this the way
    /// ModelCatalogTests checks emo and redact; keep it in step with
    /// packages/clear-* when they land.
    public static let sdkVersion = "1.0.3"
    public static let summary = "On-device speech enhancement: denoise, dereverb, and loudness-normalize."

    /// The variant this declaration describes: the SDK default. The repo also
    /// publishes `clear-natural`, which a caller selects per instance
    /// (`Clear(variant:)`) and which downloads through ``ModelVariant`` rather
    /// than through this manifest - the catalog entry stays one model's default
    /// artifact, which is what tooling and the shared test fixture expect.
    public static let variant = ModelVariant.default
    /// Core ML export (a directory on the Hub): Apple. Already ANE-friendly and
    /// 6-bit palettized, so no per-platform export shaping is needed.
    public static let coreML = variant.coreML
    /// LiteRT export: Android/Linux/Windows, and LiteRT.js on the web.
    public static let tflite = variant.tflite

    /// Unlike the text models, clear has no sidecars: the DSP front end
    /// (`DSP.swift`/`Features.swift`) carries the constants that would otherwise
    /// be a metadata file, so a platform ships exactly one artifact.
    public static let files: [ModelPlatform: [String]] = variant.files

    public static func artifact(for platform: ModelPlatform) -> String {
        variant.artifact(for: platform)
    }
}
