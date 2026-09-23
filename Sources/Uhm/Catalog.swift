import DesertAnt

/// The uhm model: on-device filler-word detection ("uh", "um", "hmm", ...)
/// with one prediction every 20 ms. One published tier (``Uhm/Quality``; the
/// HuBERT-base tier is disabled until republished): the small DistilHuBERT
/// `uhm`, hosted on the Hub as an unzipped `.mlmodelc/`.
public enum UhmModel: ModelDeclaration {
    public static let id = "uhm"
    public static let product = "Uhm"
    // `v1.1.0` runs every operation on the Neural Engine (uhm-training
    // research/PROGRESS_ane_residency.md): the `v1.0.0` weights in a graph that
    // takes a pre-tiled window and returns BC1S probabilities, which is why
    // `FillerDetector` reads its layout off the artifact. A pin is exact and a
    // published tag never moves, so older SDKs keep resolving `v1.0.0`.
    public static let revision = "v1.1.0"
    /// No published npm/Maven package, so nothing cross-checks this the way
    /// ModelCatalogTests checks emo and redact; keep it in step with
    /// packages/uhm-* if they land.
    public static let sdkVersion = "3.5.0"
    public static let summary = "On-device filler-word detection: frame-precise \"uh\"/\"um\"/\"hmm\" spans."

    /// The SDK default. A caller-selected tier (`Uhm(quality:)`) downloads
    /// through ``Uhm/Quality``: tooling and the shared test fixture expect the
    /// catalog entry to describe one default artifact.
    public static let quality = Uhm.Quality.default.resolved

    /// Core ML export (a directory on the Hub). No LiteRT export is published,
    /// so Apple is the only platform in `files`.
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
