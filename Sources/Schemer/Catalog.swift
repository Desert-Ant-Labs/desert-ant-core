// This model's catalog declaration: coordinates, file names, and which of
// them each platform ships. The shared behaviour (distribution, resolve,
// availability) comes from `ModelDeclaration` in the catalog's shared half.

import DesertAnt

/// The schemer model: on-device structured extraction into a caller-supplied
/// JSON schema.
///
/// Four graphs rather than one, and the split is load-bearing:
///
///  * two encoders because sequence length is static on every backend, and a
///    field query is ~10 tokens where the joint input is 256. Running queries
///    through the long graph costs 14 ms each for nothing.
///  * decode fuses the reader and every head whose shape does not depend on
///    the label value set, so the per-field dispatch floor is paid once.
///  * label is separate because its candidate count varies per call, and a
///    dynamic axis would force a re-plan on every backend.
public enum SchemerModel: ModelDeclaration {
    public static let id = "schemer"
    public static let product = "Schemer"
    public static let revision = "v1.1.0"
    /// Matches packages/schemer-node/package.json and
    /// packages/schemer-kotlin/build.gradle.kts (ModelCatalogTests enforces it).
    public static let sdkVersion = "3.5.0"
    public static let summary =
        "On-device structured extraction into a caller-supplied JSON schema."

    /// The encoder and decode graphs are Core ML multifunction packages (one
    /// function per sequence window over one copy of the weights), which need
    /// iOS 18 / macOS 15.
    public static let osFloor = OSFloor.multifunction

    /// mmBERT vocab, ranked merges, byte-fallback ids, added tokens, and the
    /// v53 pruned-vocabulary remap, as one length-prefixed binary.
    public static let tokenizer = "schemer_tokenizer.bin"
    /// 103324 x 768, per-row int8 with an fp16 scale (79.6 MB against 158.7
    /// at fp16). See schemer-training/training/ane/embeddings.py.
    public static let embeddings = "embeddings.q"

    public static let sidecars = [tokenizer, embeddings]

    /// One multifunction package per stage. The three encoder windows (32,
    /// 256, 1216) and the two decode windows are FUNCTIONS, so the shared
    /// weights exist once on disk: 84.9 MB for three encoder shapes against
    /// 251.6 MB as separate packages.
    public static let coreMLEncoder = "schemer-encoder.mlmodelc"
    public static let coreMLDecode = "schemer-decode.mlmodelc"
    public static let coreMLLabel = "schemer-label.mlmodelc"

    public static let liteRTEncoder = "schemer-encoder.tflite"
    public static let liteRTDecode = "schemer-decode.tflite"
    public static let liteRTLabel = "schemer-label.tflite"

    static let liteRT = [liteRTEncoder, liteRTDecode, liteRTLabel]

    public static let files: [ModelPlatform: [String]] = [
        .apple: [coreMLEncoder + "/", coreMLDecode + "/", coreMLLabel + "/"] + sidecars,
        .android: liteRT + sidecars,
        .linux: liteRT + sidecars,
        .windows: liteRT + sidecars,
        .web: liteRT + sidecars,
    ]

    public static func encoderName(for p: ModelPlatform) -> String {
        p == .apple ? coreMLEncoder : liteRTEncoder
    }
    public static func decodeName(for p: ModelPlatform) -> String {
        p == .apple ? coreMLDecode : liteRTDecode
    }
    public static func labelName(for p: ModelPlatform) -> String {
        p == .apple ? coreMLLabel : liteRTLabel
    }

    public static var encoder: String { encoderName(for: ModelPlatform.current) }
    public static var decode: String { decodeName(for: ModelPlatform.current) }
    public static var label: String { labelName(for: ModelPlatform.current) }

    /// `ModelDeclaration` wants a single primary artifact; the encoder is the
    /// one that dominates both size and time, so it stands for the set.
    public static func artifact(for platform: ModelPlatform) -> String {
        encoderName(for: platform)
    }
}
