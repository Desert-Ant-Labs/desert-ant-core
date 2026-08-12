// This model's catalog declaration: coordinates, file names, and which of them
// each platform ships. The shared behaviour (distribution, resolve, availability)
// comes from `ModelDeclaration` in the catalog's shared half.

import DesertAnt

/// The title model: a short factual title and a one- to two-sentence description
/// for a passage of text.
///
/// **The only MLX model in this package, and the only Apple-exclusive one.** Every other
/// model here runs through `InferenceSession` — Core ML on Apple, LiteRT elsewhere. This one
/// does not, and the reason is measured rather than architectural: writing a title is short
/// autoregressive decode, which the Neural Engine is bandwidth-bound for. Commit `8e97532`
/// benchmarked the Core ML path and removed `MLState` when it lost — `CPU_AND_NE` could not
/// build an execution plan from `model.mil` at all (error -14), and Core ML's best showing was
/// its CPU one at 213 ms to first token against MLX's 55 ms, 86 tok/s against 447, and 1921 MB
/// resident against 635.
///
/// `title-training/release/` still carries `title-coreml/`, `title-coreai/` and `title-onnx/`.
/// Those are the losing exports kept as evidence, not pending candidates. Do not read their
/// existence as a Core ML path waiting to be wired up.
///
/// **Consequences of being MLX, stated here so they are not rediscovered:**
///
///   * `Title` is a SEPARATE product. A consumer that only selects clips must not pay for an
///     MLX build, which is the same reasoning that keeps JavaScriptKit off every non-wasm
///     graph in `Package.swift`.
///   * There is no `.android`, `.linux`, `.windows` or `.web` entry in ``files``. MLX is Apple
///     only. `supports(_:)` therefore returns false for them, which is the honest answer
///     rather than a manifest promising files that cannot run.
///   * The artifact is an MLX model FOLDER (`config.json`, `model.safetensors`,
///     `tokenizer.json`), not a compiled graph, so it does not follow the
///     `<model>.mlmodelc` / `<model>.tflite` shape the other models share.
public enum TitleModel: ModelDeclaration {
    public static let id = "title"
    public static let product = "Title"
    /// Pinned. The exception this used to claim — "the published repo carries
    /// `title-mlx-6bit.*`, and the file names below do not match it" — expired when the repo
    /// was republished: all seven names in ``files`` exist at `v0.1.0`, checked against the
    /// Hub listing.
    ///
    /// A justification that outlives the condition it describes is worse than none, because it
    /// reads as a decision somebody made rather than a state nobody rechecked. `ModelCatalogTests`
    /// permits `main` only as a documented exception, and Title is absent from that test's
    /// catalog list, so nothing here would have caught the staleness.
    public static let revision = "v0.1.0"
    /// MLX has no build below macOS 14 / iOS 17. Unlike Clips this is a DEPENDENCY floor, not
    /// an artifact one, so `Package.swift` must also rise when the MLX dependency is pulled in
    /// — SwiftPM resolves platforms at manifest level and no declaration here can satisfy it.
    public static let osFloor = OSFloor.mlx

    public static let sdkVersion = "3.0.0"
    public static let summary =
        "On-device titles and descriptions: a short factual title and a one- to two-sentence "
        + "description for any passage of text."

    /// The MLX weights. 6-bit quantized Granite at roughly 280 MB — produced by
    /// `title-training/python/quantize_mlx.py` and packaged by its `package.py`.
    public static let weights = "model.safetensors"
    /// Shard index. Present even for a single shard, because `ModelConfiguration` reads it.
    public static let weightsIndex = "model.safetensors.index.json"
    /// Architecture and quantization config. MLX reads this to build the graph.
    public static let config = "config.json"
    /// Decode defaults. Read by MLX, not by this SDK.
    public static let generationConfig = "generation_config.json"
    /// Byte-level BPE with merges — the `TTOK` family, NOT interchangeable with the `RDTK`
    /// tokenizer `Clips` uses. Both are "a tokenizer binary" and they are different formats.
    public static let tokenizer = "tokenizer.json"
    public static let tokenizerConfig = "tokenizer_config.json"
    /// The chat template the fine-tune was trained against. `MLXLMCommon` applies it, and a
    /// different template is a different task to the model.
    public static let chatTemplate = "chat_template.jinja"

    /// APPLE ONLY. See the type's note: MLX has no other platform, and declaring a file list
    /// for one would promise an artifact that cannot load.
    public static let files: [ModelPlatform: [String]] = [
        .apple: [weights, weightsIndex, config, generationConfig,
                 tokenizer, tokenizerConfig, chatTemplate],
    ]

    /// The weights are what the shared declaration considers *the* model, though MLX loads the
    /// whole directory rather than one file.
    public static func artifact(for platform: ModelPlatform) -> String { weights }
}
