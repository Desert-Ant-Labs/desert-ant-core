// This model's catalog declaration: coordinates, file names, and which of them
// each platform ships. The shared behaviour (distribution, resolve, availability)
// comes from `ModelDeclaration` in the catalog's shared half.

import DesertAnt

/// The uhm model: on-device filler-word detection ("uh", "um", "hmm", ...)
/// with one prediction every 20 ms. One published tier (``Uhm/Quality``; the
/// standalone SDK's second, HuBERT-base tier is disabled until republished):
/// the small, fast DistilHuBERT `uhm`, hosted on the Hub as a precompiled,
/// unzipped `.mlmodelc/`, which is exactly the store's expected layout.
public enum UhmModel: ModelDeclaration {
    public static let id = "uhm"
    public static let product = "Uhm"
    // The Hub tag this SDK is built against. `v1.1.0` is the re-export whose
    // every operation runs on the Neural Engine (uhm-training
    // research/PROGRESS_ane_residency.md): the same weights as `v1.0.0`, in a
    // graph that takes a pre-tiled window and returns BC1S probabilities -
    // which is why `FillerDetector` reads its layout off the artifact rather
    // than assuming one.
    //
    // A pin is exact and a published tag does not move, so SDKs released before
    // this keep resolving `v1.0.0` and keep working: a model release and an SDK
    // release never have to happen together.
    public static let revision = "v1.1.0"
    /// The standalone uhm-swift release this port matches. No published
    /// npm/Maven package yet, so nothing cross-checks this the way
    /// ModelCatalogTests checks emo and redact; keep it in step with
    /// packages/uhm-* when they land.
    public static let sdkVersion = "3.4.0"
    public static let summary = "On-device filler-word detection: frame-precise \"uh\"/\"um\"/\"hmm\" spans."

    /// The tier this declaration describes: the SDK default's resolution.
    /// A caller-selected tier (`Uhm(quality:)`) downloads through
    /// ``Uhm/Quality`` rather than through this manifest - the catalog entry
    /// stays one model's default artifact, which is what tooling and the
    /// shared test fixture expect.
    public static let quality = Uhm.Quality.default.resolved

    /// Core ML export (a directory on the Hub): Apple. No LiteRT export has
    /// been published, so Apple is currently the only platform in `files`.
    public static let coreML = quality.coreML

    /// The ~13 KB per-filler type-labeler head (SoundAnalysis, Apple-only),
    /// downloaded alongside the detector. Tier-independent: both qualities'
    /// file lists include it.
    public static let labeler = "UhmLabel.mlmodel"

    /// The detector's constants (window length, frame hop, thresholds) live in
    /// `Detector.swift`, so there are no config sidecars: Apple ships the
    /// detector plus the tiny type-labeler head.
    public static let files: [ModelPlatform: [String]] = quality.files

    public static func artifact(for platform: ModelPlatform) -> String {
        quality.artifact(for: platform)
    }
}
