import DesertAnt

/// The toxic model: on-device hate-speech triage. One graph per runtime, each in its own folder on the Hub with
/// its own `toxic_meta.json` (the tensor names, the heads, the default thresholds); the tokenizer at the top of
/// the repo serves both.
public enum ToxicModel: ModelDeclaration {
    public static let id = "toxic"
    public static let product = "Toxic"
    public static let revision = "v0.2.2"
    public static let sdkVersion = "4.3.0"
    public static let summary = "On-device hate-speech triage for European languages."

    /// The tokenizer as the SDK reads it, shared by every runtime: the pieces, the merges and the added tokens.
    public static let tokenizer = "toxic_tokenizer.bin"
    /// The embedding table as the SDK reads it, shared by every runtime: the SDK looks a text's rows up itself and
    /// feeds the graph embeddings, so the graph has no lookup and runs on the Neural Engine whole.
    public static let table = "toxic_table.bin"
    /// Per runtime folder: the graph's input and output names, the heads in output order, the tokenizer's
    /// window and special ids, the default threshold per head.
    public static let meta = "toxic_meta.json"

    /// The Hub folder a platform reads: the compiled Core ML program on Apple platforms, the LiteRT file
    /// elsewhere, both with the embedding table at 4-bit and the layers at 8-bit.
    public static func directory(for platform: ModelPlatform) -> String {
        platform == .apple ? "coreml-mixed" : "litert-mixed"
    }

    /// The platform's meta, relative to the repo root.
    public static func meta(for platform: ModelPlatform) -> String {
        "\(directory(for: platform))/\(meta)"
    }

    /// Both graphs take `embeddings`, `[1, 128, 384]`, and a float `attention_mask`, `[1, 128]`, and return
    /// `probabilities`, `[1, 11]`, one per head in the meta's order.
    public static func artifact(for platform: ModelPlatform) -> String {
        "\(directory(for: platform))/" + (platform == .apple ? "\(id).mlmodelc" : "\(id).tflite")
    }

    public static let files: [ModelPlatform: [String]] = Dictionary(uniqueKeysWithValues: ModelPlatform.allCases.map { platform in
        (platform, [artifact(for: platform) + (platform == .apple ? "/" : ""), meta(for: platform), tokenizer, table])
    })

    /// The Core ML program targets iOS 18 and macOS 15; the LiteRT file runs anywhere.
    public static let osFloor = OSFloor.multifunction
}
