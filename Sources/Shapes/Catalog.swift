import DesertAnt

/// The shapes model: on-device shape recognition from a few strokes of ink.
public enum ShapesModel: ModelDeclaration {
    public static let id = "shapes"
    public static let product = "Shapes"
    public static let revision = "v2.2.0"
    public static let sdkVersion = "5.0.0"
    public static let summary = "On-device shape recognition for pen, touch and mouse input."

    /// Per build folder: the kinds, the input steps, where each kind's numbers
    /// sit in the outputs, and the residual gates.
    public static let meta = "shapes_meta.json"

    /// The Hub folder a platform reads: the compiled Core ML program with 4-bit
    /// palettized weights on Apple platforms, the LiteRT file with 8-bit
    /// weights elsewhere.
    public static func directory(for platform: ModelPlatform) -> String {
        platform == .apple ? "coreml-palette4" : "litert-int8"
    }

    /// The platform's meta, relative to the repo root.
    public static func meta(for platform: ModelPlatform) -> String {
        "\(directory(for: platform))/\(meta)"
    }

    /// Both builds take `x` [1, 256, C] (the drawing as `Ink` prepares it, C
    /// the meta's channels) and `stroke` [1, 256] (each point's stroke index),
    /// and return `kind_logits` [1, 18] and `numbers` [1, 125] (every kind's
    /// template numbers, laid out in the meta).
    public static func artifact(for platform: ModelPlatform) -> String {
        "\(directory(for: platform))/" + (platform == .apple ? "\(id).mlmodelc" : "\(id).tflite")
    }

    public static let files: [ModelPlatform: [String]] = Dictionary(uniqueKeysWithValues: ModelPlatform.allCases.map { platform in
        (platform, [artifact(for: platform) + (platform == .apple ? "/" : ""), meta(for: platform)])
    })
}
