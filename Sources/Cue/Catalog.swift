// This model's catalog declaration: coordinates, file names, and which of them
// each platform ships. The shared behaviour (distribution, resolve, availability)
// comes from `ModelDeclaration` in the catalog's shared half.

import DesertAnt

/// The cue model: on-device voice activity detection.
///
/// Apple-only. The runtime drives Core ML directly rather than going through
/// `InferenceSession` because the graph is a fixed-shape window fed by a
/// host-side filterbank, and the chunking that makes it exact needs to control
/// its own buffers.
public enum CueModel: ModelDeclaration {
    public static let id = "cue"
    public static let product = "Cue"
    public static let revision = "v0.1.0"
    /// Matches VERSION (check:version enforces it; this repo releases as one).
    public static let sdkVersion = "3.0.0"
    public static let summary =
        "On-device voice activity detection: frame-precise speech spans, any language."

    /// Names describe roles rather than the network behind them, so replacing
    /// the detector is a new upload rather than an SDK change. The current
    /// export is a FireRedVAD DFSMN re-authored for the Neural Engine and
    /// palettized to 4 bits; nothing outside this comment depends on that.
    ///
    /// Compiled Core ML program, not an `.mlpackage`: Core ML keys its
    /// specialized Neural Engine program cache on the compiled model's path, so
    /// an `.mlpackage` recompiles into a fresh temporary directory on every
    /// launch and never hits that cache.
    public static let weights = "cue.mlmodelc"
    /// Frontend geometry, receptive field, and the segmentation defaults. The
    /// runtime refuses to hardcode these so a re-export cannot silently
    /// disagree with the filterbank that feeds it.
    public static let meta = "cue_meta.json"

    public static let files: [ModelPlatform: [String]] = [
        .apple: [weights + "/", meta],
    ]

    public static func artifact(for platform: ModelPlatform) -> String { weights }
}
