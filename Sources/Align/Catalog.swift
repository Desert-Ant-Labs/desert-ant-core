// This model's catalog declaration: coordinates, file names, and which of them
// each platform ships. The shared behavior (distribution, resolve, availability)
// comes from `ModelDeclaration` in the catalog's shared half.

import DesertAnt

/// Word-timestamp refinement for any transcript: Core ML on Apple, LiteRT elsewhere; no web, the cascade is two graphs.
public enum AlignModel: ModelDeclaration {
    public static let id = "align"
    public static let product = "Align"
    /// Pinned tag; v1.1.0 adds the LiteRT export and renames the unchanged Core ML weights
    /// to kebab-case. The SDK resolves weights by this revision, so tracking a branch would
    /// change behavior for every installed copy the moment new weights land on the Hub.
    public static let revision = "v1.1.0"
    /// Matches VERSION (check:version enforces it; this repo releases as one).
    public static let sdkVersion = "3.2.0"
    public static let summary = "Word-timestamp refinement for any transcript, on device."

    /// Coarse cascade stage (Core ML, a directory on the Hub).
    public static let coarse = "align-coarse.mlmodelc"
    /// Fine cascade stage (Core ML, a directory on the Hub).
    public static let fine = "align-fine.mlmodelc"
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

    /// The Core ML export names its logits output this; the LiteRT export names it `logits`.
    public static let coreMLOutput = "var_155"
    public static let tfliteOutput = "logits"
    /// Which of the two a stage session returns, by the platform whose artifact it opened.
    public static func outputName(for platform: ModelPlatform) -> String {
        platform == .apple ? coreMLOutput : tfliteOutput
    }

    // No `.android` entry: the host bridge has no NFC and the lexical bytes must match training.
    public static let files: [ModelPlatform: [String]] = [
        .apple: [coarse + "/", fine + "/"] + sidecars,
        .linux: [coarseTFLite, fineTFLite] + sidecars,
        .windows: [coarseTFLite, fineTFLite] + sidecars,
    ]

    /// The cascade's first stage, per platform.
    public static func coarseArtifact(for platform: ModelPlatform) -> String {
        platform == .apple ? coarse : coarseTFLite
    }

    /// The cascade's second stage, per platform.
    public static func fineArtifact(for platform: ModelPlatform) -> String {
        platform == .apple ? fine : fineTFLite
    }

    /// The cascade runs coarse-then-fine; the coarse stage is the entry point.
    public static func artifact(for platform: ModelPlatform) -> String { coarseArtifact(for: platform) }
}
