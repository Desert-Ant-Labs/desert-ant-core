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
    public static let sdkVersion = "0.1.0"
    public static let summary = "On-device speech enhancement: denoise, dereverb, and loudness-normalize."

    /// The published variant this SDK is built against. The repo also ships a
    /// `clear-natural` export; switching variants is a file-name change here.
    public static let variant = "clear-studio"
    /// Core ML export (a directory on the Hub): Apple. Already ANE-friendly and
    /// 6-bit palettized, so no per-platform export shaping is needed.
    public static let coreML = "\(variant).mlmodelc"
    /// LiteRT export: Android/Linux/Windows, and LiteRT.js on the web.
    public static let tflite = "\(variant).tflite"

    /// Unlike the text models, clear has no sidecars: the DSP front end
    /// (`DSP.swift`/`Features.swift`) carries the constants that would otherwise
    /// be a metadata file, so a platform ships exactly one artifact.
    public static let files: [ModelPlatform: [String]] = [
        .apple: [coreML + "/"],
        .android: [tflite],
        .linux: [tflite],
        .windows: [tflite],
        .web: [tflite],
    ]

    public static func artifact(for platform: ModelPlatform) -> String {
        platform == .apple ? coreML : tflite
    }
}
