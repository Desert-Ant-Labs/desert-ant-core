// This model's catalog declaration: coordinates, file names, and which of them
// each platform ships. The shared behaviour (distribution, resolve, availability)
// comes from `ModelDeclaration` in the catalog's shared half.

import DesertAnt

/// The scribe model: on-device speech recognition.
///
/// Apple-only. The runtime drives Core ML directly rather than going through
/// `InferenceSession`, because the things that make it fast -- preallocated
/// buffers, `outputBackings`, and a lane-batched decode loop -- are not
/// expressible through a generic run(inputs:outputs:) shape. There is therefore
/// no Android, Linux or web entry here.
public enum ScribeModel: ModelDeclaration {
    public static let id = "scribe"
    public static let product = "Scribe"
    public static let revision = "main"
    /// Matches VERSION (check:version enforces it; this repo releases as one).
    public static let sdkVersion = "3.0.0"
    public static let summary =
        "On-device speech recognition: transcripts with word-level timestamps, 25 languages."

    /// Artifact names describe roles rather than the network behind them, so
    /// replacing the recogniser is a new upload rather than an SDK change. The
    /// current export is a Parakeet TDT 0.6B v3 conformer transducer; nothing
    /// outside this comment depends on that.
    ///
    /// Compiled Core ML programs, not `.mlpackage`s. Core ML keys its specialized
    /// Neural Engine program cache on the compiled model's path, so loading an
    /// `.mlpackage` recompiles into a fresh temporary directory on every launch
    /// and never hits that cache: measured 27.9 s per load against 0.13 s.
    public static let encoder = "encoder.mlmodelc"
    public static let mel = "mel.mlmodelc"
    public static let decodeStep = "decoder.mlmodelc"

    /// Sidecars: geometry the runtime refuses to hardcode (`meta.json`), the
    /// sentencepiece vocabulary, and the prediction network's embedding table,
    /// which is a host-side lookup rather than a graph op. The table ships as
    /// float16 because that is what the decode step consumes -- float32 would be
    /// 10 MB more to download and a conversion at load for no added precision.
    public static let files: [ModelPlatform: [String]] = [
        .apple: [encoder + "/", mel + "/", decodeStep + "/",
                 "meta.json", "vocab.json", "embedding.f16"],
    ]

    public static func artifact(for platform: ModelPlatform) -> String { encoder }
}
