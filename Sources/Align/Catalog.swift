// This model's catalog declaration: coordinates, file names, and which of them
// each platform ships. The shared behaviour (distribution, resolve, availability)
// comes from `ModelDeclaration` in the catalog's shared half.

import DesertAnt

/// The align model: on-device word-timestamp refinement for Apple's Speech
/// pipeline. Apple-only, so the manifest declares files for no other platform.
public enum AlignModel: ModelDeclaration {
    public static let id = "align"
    public static let product = "Align"
    /// Pinned, not "main". The SDK resolves weights by this revision, so tracking a
    /// branch would change behaviour for every installed copy the moment new weights
    /// land on the Hub. v1.0.0 is the multilingual cascade whose accuracy figures the
    /// model page quotes; v0.1.0 tags the weights that shipped before it.
    public static let revision = "v1.0.0"
    /// Matches VERSION (check:version enforces it; this repo releases as one).
    public static let sdkVersion = "3.2.0"
    public static let summary = "Word-timestamp refinement for Apple's SpeechAnalyzer pipeline."

    /// Coarse cascade stage (Core ML, a directory on the Hub).
    public static let coarse = "align_coarse.mlmodelc"
    /// Fine cascade stage (Core ML, a directory on the Hub).
    public static let fine = "align_fine.mlmodelc"
    /// The same two stages exported for LiteRT.
    public static let coarseTFLite = "align-coarse.tflite"
    public static let fineTFLite = "align-fine.tflite"

    /// Frontend geometry, language table and cascade widths.
    public static let config = "refiner_config.json"
    /// `n_mels * bins` little-endian float32, no header.
    public static let melFilters = "mel_filters.bin"
    /// The gradient-boosted correction policy, in the `ALGN` binary format.
    public static let calibratorFile = "calibrator.bin"

    /// Sidecars the refiner needs alongside the two stages.
    public static let sidecars = [config, melFilters, calibratorFile]

    /// The cascade's first stage, per platform.
    public static func coarseArtifact(for platform: ModelPlatform) -> String {
        platform == .apple ? coarse : coarseTFLite
    }

    /// The cascade's second stage, per platform.
    public static func fineArtifact(for platform: ModelPlatform) -> String {
        platform == .apple ? fine : fineTFLite
    }

    /// The Core ML export names its logits output this; the LiteRT export names it `logits`.
    public static let coreMLOutput = "var_155"
    public static let tfliteOutput = "logits"
    /// Which of the two a stage session returns, by the platform whose artifact it opened.
    public static func outputName(for platform: ModelPlatform) -> String {
        platform == .apple ? coreMLOutput : tfliteOutput
    }

    public static let files: [ModelPlatform: [String]] = [
        .apple: [coarse + "/", fine + "/"] + sidecars,
    ]

    /// The cascade runs coarse-then-fine; the coarse stage is the entry point.
    public static func artifact(for platform: ModelPlatform) -> String { coarseArtifact(for: platform) }
}
