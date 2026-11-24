import DesertAnt

/// The title model: a short factual title and a one- to two-sentence description
/// for a passage of text.
///
/// Title runs on MLX on Apple and LiteRT-LM on Android. Writing a title
/// is short autoregressive decode, which the Neural Engine is bandwidth-bound for. Benchmarked
/// in commit `8e97532`: `CPU_AND_NE` could not build an execution plan from `model.mil`
/// (error -14), and Core ML's best showing (CPU) was 213 ms to first token against MLX's
/// 55 ms, 86 tok/s against 447, and 1921 MB resident against 635.
///
/// The `title-coreml/`, `title-coreai/` and `title-onnx/` exports in `title-training/release/`
/// are the losing exports kept as evidence, not a Core ML path waiting to be wired up.
///
public enum TitleModel: ModelDeclaration {
    public static let id = "title"
    public static let product = "Title"
    public static let revision = "v0.2.0"
    /// MLX has no build below macOS 14 / iOS 17. This is a dependency floor, not an artifact
    /// one, so `Package.swift` must also rise when the MLX dependency is pulled in: SwiftPM
    /// resolves platforms at manifest level and no declaration here can satisfy it.
    public static let osFloor = OSFloor.mlx

    public static let sdkVersion = "6.0.0"
    public static let summary =
        "On-device titles and descriptions: a short factual title and a one- to two-sentence "
        + "description for any passage of text."

    /// 6-bit quantized Granite, roughly 280 MB, produced by
    /// `title-training/python/quantize_mlx.py` and packaged by its `package.py`.
    public static let weights = "model.safetensors"
    /// Shard index. Present even for a single shard, because `ModelConfiguration` reads it.
    public static let weightsIndex = "model.safetensors.index.json"
    /// Architecture and quantization config. MLX reads this to build the graph.
    public static let config = "config.json"
    /// Decode defaults. Read by MLX, not by this SDK.
    public static let generationConfig = "generation_config.json"
    /// Byte-level BPE with merges (the `TTOK` family), not interchangeable with the `RDTK`
    /// tokenizer `Clips` uses.
    public static let tokenizer = "tokenizer.json"
    public static let tokenizerConfig = "tokenizer_config.json"
    /// The chat template the fine-tune was trained against. `MLXLMCommon` applies it, and a
    /// different template is a different task to the model.
    public static let chatTemplate = "chat_template.jinja"

    /// The Android bundle contains the tokenizer and the model's stop conditions.
    public static let liteRTBundle = "litert/title.litertlm"

    public static let files: [ModelPlatform: [String]] = [
        .apple: [weights, weightsIndex, config, generationConfig,
                 tokenizer, tokenizerConfig, chatTemplate],
        .android: [liteRTBundle],
    ]

    /// The weights are what the shared declaration considers *the* model, though MLX loads the
    /// whole directory rather than one file.
    public static func artifact(for platform: ModelPlatform) -> String {
        platform == .android ? liteRTBundle : weights
    }
}
