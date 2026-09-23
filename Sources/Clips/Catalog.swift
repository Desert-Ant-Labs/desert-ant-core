import DesertAnt

/// The clip model: on-device selection of a transcript's best moments.
///
/// Two graphs: a per-sentence *selector* (saliency plus start/end probabilities,
/// which propose candidate spans) and a per-span *scorer*. They are separate
/// because the selector also reads five discourse scalars the scorer does not.
/// `artifact(for:)` names the selector's file, since the shared declaration is
/// single-artifact; ``selector(for:)`` and ``scorer(for:)`` name the function
/// inside the file as well as the file.
public enum ClipModel: ModelDeclaration {
    public static let id = "clips"
    public static let product = "Clips"
    // `v0.1.0` is the first tag whose artifacts match the names below: one
    // multifunction `clips.mlmodelc` and a LiteRT pair at the same widths, all from
    // `runs/win256` (checkpoint digest `fe11c7852ef0421e`). Pinning matters more than
    // usual: the scorer's window is the axis the arms vary on, so a moved repo would
    // hand the SDK a graph of a different width, caught by nothing but wrong clips.
    public static let revision = "v0.1.0"
    /// `clips.mlmodelc` is a multifunction package, an iOS 18 feature (the compiled
    /// artifact declares specificationVersion 9). Stated here rather than in
    /// `Package.swift` so the other models keep the package floor.
    public static let osFloor = OSFloor.multifunction

    /// No published npm/Maven package (see `docs/development.md`: a model with an
    /// npm package must run real inference in headless Chromium, and this one
    /// needs two sessions, which the wasm host cannot give it). Nothing
    /// cross-checks this the way `ModelCatalogTests` checks emo and redact; keep
    /// it in step with `packages/clips-*` if they land.
    public static let sdkVersion = "3.5.0"
    public static let summary = "Short clips and highlights from talking video and audio: podcasts, interviews, meetings. On-device."

    /// The artifact family this SDK is built against. Every file name below derives
    /// from this stem, so changing the shipped export is this line plus the Hub tag.
    ///
    /// The shipped quantization is int8 per-channel, 284 MB, `select` [16,128] and
    /// `score` [16,256], from `runs/win256` (digest `fe11c7852ef0421e`). It ties fp16
    /// on judged clips in every stratum at half the size; int4 is 2.0-2.7x slower on
    /// the ANE with a mean selection IoU of 0.130 against its own reference; and
    /// every LUT scheme doubles the trunk, because `save_multifunction` dedups by
    /// hashing constant values and palettized weights do not collide. See
    /// `clips-training/docs/quant-decision.md`.
    public static let stem = "clips"

    /// XLM-R SentencePiece **Unigram** vocab in the compact binary
    /// `Tokenizer.swift` reads. Token ids must match training exactly, so the
    /// vocab ships with the model rather than being reconstructed.
    public static let tokenizer = "clip_tokenizer.bin"

    /// Half of the pipeline: the artifact to open, and which function inside it
    /// to run when it carries more than one graph. A file name alone does not
    /// identify a model on Core ML.
    public struct Export: Sendable, Equatable {
        /// Repo-relative artifact, exactly as it appears in ``files``.
        public let file: String
        /// The Core ML function to load, or `nil` for a single-graph artifact.
        public let function: String?
    }

    /// Core ML export (a directory on the Hub): one multifunction package
    /// carrying both graphs over their shared encoder, as the functions `select`
    /// and `score`. The 278M-parameter trunk is stored once, so the asset (and
    /// the download) is 284 MB against 535 MB for two separate packages.
    ///
    /// Reaching a function needs `MLModelConfiguration.functionName`, which
    /// ``Export/function`` carries to `Sources/Inference/CoreMLSession.swift`.
    /// Without it Core ML silently loads the default function, so both halves of
    /// the pipeline would be the selector.
    public static let coreML = "\(stem).mlmodelc"
    public static let selectFunction = "select"
    public static let scoreFunction = "score"

    /// LiteRT exports: Android/Linux/Windows. LiteRT has no multifunction
    /// packaging, so those platforms ship two files and pay for the shared
    /// trunk twice.
    public static let selectorTFLite = "\(stem)-selector.tflite"
    public static let scorerTFLite = "\(stem)-scorer.tflite"

    /// Sidecars every platform needs alongside the artifacts.
    public static let sidecars = [tokenizer]

    // No `.web` entry. The wasm host holds one compiled model per module
    // (`docs/development.md`) and selection needs two, so a browser build would
    // resolve files it could not both compile.
    public static let files: [ModelPlatform: [String]] = [
        .apple: [coreML + "/"] + sidecars,
        .android: [selectorTFLite, scorerTFLite] + sidecars,
        .linux: [selectorTFLite, scorerTFLite] + sidecars,
        .windows: [selectorTFLite, scorerTFLite] + sidecars,
    ]

    /// The per-sentence selector: the first half of the pipeline, and what the
    /// shared declaration considers *the* model.
    public static func selector(for platform: ModelPlatform) -> Export {
        platform == .apple
            ? Export(file: coreML, function: selectFunction)
            : Export(file: selectorTFLite, function: nil)
    }

    /// The span scorer, the second half of the pipeline. On Apple this is the
    /// same file as ``selector(for:)`` under a different function.
    public static func scorer(for platform: ModelPlatform) -> Export {
        platform == .apple
            ? Export(file: coreML, function: scoreFunction)
            : Export(file: scorerTFLite, function: nil)
    }

    public static func artifact(for platform: ModelPlatform) -> String {
        selector(for: platform).file
    }

    /// The two halves for the platform being built for.
    public static var selector: Export { selector(for: .current) }
    public static var scorer: Export { scorer(for: .current) }
}
