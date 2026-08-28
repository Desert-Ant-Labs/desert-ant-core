// This model's catalog declaration: coordinates, file names, and which of them
// each platform ships. The shared behaviour (distribution, resolve, availability)
// comes from `ModelDeclaration` in the catalog's shared half.

import DesertAnt

/// The align model: on-device word-timestamp refinement for Apple's Speech
/// pipeline. Apple-only, so the manifest declares files for no other platform.
public enum AlignModel: ModelDeclaration {
    public static let id = "align"
    public static let product = "Align"
    // TODO: pin to a tagged revision once the align model repo is tagged.
    public static let revision = "main"
    /// Matches VERSION (check:version enforces it; this repo releases as one).
    public static let sdkVersion = "3.1.0"
    public static let summary = "Word-timestamp refinement for Apple's SpeechAnalyzer pipeline."

    /// Coarse cascade stage (Core ML, a directory on the Hub).
    public static let coarse = "align_coarse.mlmodelc"
    /// Fine cascade stage (Core ML, a directory on the Hub).
    public static let fine = "align_fine.mlmodelc"

    /// Sidecars the refiner needs alongside the two stages.
    public static let sidecars = ["refiner_config.json", "mel_filters.bin", "calibrator.bin"]

    public static let files: [ModelPlatform: [String]] = [
        .apple: [coarse + "/", fine + "/"] + sidecars,
    ]

    /// The cascade runs coarse-then-fine; the coarse stage is the entry point.
    public static func artifact(for platform: ModelPlatform) -> String { coarse }
}
