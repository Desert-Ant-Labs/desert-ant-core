// This model's catalog declaration: coordinates, file names, and which of them
// each platform ships. The shared behaviour (distribution, resolve, availability)
// comes from `ModelDeclaration` in the catalog's shared half.

import DesertAnt

/// The voz model: on-device speech recognition.
///
/// The runtime drives its inference backend directly (Core ML on Apple, the
/// LiteRT C shim on Android/Linux) rather than going through
/// `InferenceSession`, because the things that make it fast - preallocated
/// buffers, `outputBackings`, and a lane-batched decode loop - are not
/// expressible through a generic run(inputs:outputs:) shape. There is no web
/// entry here.
public enum VozModel: ModelDeclaration {
    public static let id = "voz"
    public static let product = "Voz"
    public static let revision = "v0.2.0"
    /// Matches VERSION (check:version enforces it; this repo releases as one).
    public static let sdkVersion = "3.1.0"
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

    /// The same three graphs as LiteRT programs, for Android/Linux. Same
    /// conversion pipeline; the engine checks shapes at load (the export names
    /// its signature tensors `args_N`, so names carry nothing to check).
    public static let encoderLiteRT = "encoder.tflite"
    public static let melLiteRT = "mel.tflite"
    public static let decodeStepLiteRT = "decoder.tflite"
    /// The LiteRT export's own geometry. Separate from `meta.json` because the
    /// two exports genuinely differ (float32 I/O, decode width 1, one lane),
    /// and reading the Apple file would size every decode buffer wrong.
    public static let litertMeta = "meta.litert.json"

    /// Sidecars: geometry the runtime refuses to hardcode (`meta.json`), the
    /// sentencepiece vocabulary, and the prediction network's embedding table,
    /// which is a host-side lookup rather than a graph op. The table ships as
    /// float16 because that is what the decode step consumes - float32 would be
    /// 10 MB more to download and a conversion at load for no added precision.
    private static let litertFiles =
        [encoderLiteRT, melLiteRT, decodeStepLiteRT, litertMeta, "vocab.json", "embedding.f16"]

    public static let files: [ModelPlatform: [String]] = [
        .apple: [encoder + "/", mel + "/", decodeStep + "/",
                 "meta.json", "vocab.json", "embedding.f16"],
        .android: litertFiles,
        .linux: litertFiles,
    ]

    public static func artifact(for platform: ModelPlatform) -> String {
        platform == .apple ? encoder : encoderLiteRT
    }
}
