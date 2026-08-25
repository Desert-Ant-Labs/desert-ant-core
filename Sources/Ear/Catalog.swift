// This model's catalog declaration: coordinates, file names, and which of them
// each platform ships. The shared behaviour (distribution, resolve, availability)
// comes from `ModelDeclaration` in the catalog's shared half.

import DesertAnt

/// The ear model: on-device spoken language identification.
///
/// Every platform runs the same graph shape -- log-mel in, language logits out
/// -- because the frontend is Swift (`Frontend.swift`) rather than part of the
/// artifact. That is not only for symmetry: the frontend cannot run in float16,
/// so folding it into the Core ML program would either drop the whole thing off
/// the Neural Engine or destroy the features. Measured, a float16 frontend takes
/// routing accuracy from 97.5% to 84.2%. Swift computes it in Float and hands
/// the model the one tensor it wants.
public enum EarModel: ModelDeclaration {
    public static let id = "ear"
    public static let product = "Ear"
    /// Pinned to a tag rather than a branch. A branch means a push to the Hub
    /// silently changes what already-shipped SDKs download, which is the kind of
    /// change nobody is looking for when something starts behaving differently.
    public static let revision = "v0.1.0"
    /// Matches VERSION (check:version enforces it; this repo releases as one).
    public static let sdkVersion = "3.0.0"
    public static let summary = "On-device spoken language identification across 99 languages."

    /// Artifact names describe roles rather than the network behind them, so
    /// replacing the detector is a new upload rather than an SDK change.
    ///
    /// The Apple artifact is a compiled Core ML program, not an `.mlpackage`.
    /// Core ML keys its specialized Neural Engine program cache on the compiled
    /// model's path, so an `.mlpackage` recompiles into a fresh temporary
    /// directory on every launch and never hits that cache.
    public static let coreML = "ear.mlmodelc"
    public static let liteRT = "ear.tflite"

    /// Sidecars: the language codes in head order, the geometry the frontend
    /// refuses to hardcode, and the mel filterbank. The filterbank ships as a
    /// table rather than being rebuilt in Swift because the reference filters
    /// are slaney-normalized librosa output, and reimplementing that is a source
    /// of silent drift for the sake of 64 KB.
    public static let languages = "languages.json"
    public static let meta = "ear_meta.json"
    public static let melFilters = "mel_filters.f32"

    private static let sidecars = [languages, meta, melFilters]

    public static let files: [ModelPlatform: [String]] = [
        .apple: [coreML + "/"] + sidecars,
        .android: [liteRT] + sidecars,
        .linux: [liteRT] + sidecars,
        .windows: [liteRT] + sidecars,
        .web: [liteRT] + sidecars,
    ]

    public static func artifact(for platform: ModelPlatform) -> String {
        platform == .apple ? coreML : liteRT
    }
}
