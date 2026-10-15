import DesertAnt

/// The who model: on-device speaker diarization in one pass. The artifact is a
/// pair of fixed-shape graphs per window length and a voice graph, run over the
/// pieces of a recording: Core ML programs on Apple platforms in two precisions,
/// LiteRT models elsewhere at int8.
public enum WhoModel: ModelDeclaration {
    public static let id = "who"
    public static let product = "Who"
    public static let revision = "v0.3.1"
    public static let sdkVersion = "4.0.0"
    public static let summary = "On-device speaker labeling: per-person turns with timestamps."

    /// The platform's default; on Apple platforms `int8` is selected with `Who(variant:)`.
    public static let variant = ModelVariant.default

    /// Sidecars, one copy per variant directory: the geometry, the two filterbanks' filters as tables, and
    /// the embedding layer the voices go through.
    public static let meta = "who_meta.json"
    public static let melBanks = "who_mel_banks.f32"
    public static let voiceBanks = "who_voice_banks.f32"
    public static let embedding = "who_embed.f16"

    public static let files: [ModelPlatform: [String]] = variant.files
    /// The Core ML graphs are multifunction-era programs for the Neural Engine; the LiteRT ones run anywhere.
    public static let osFloor = OSFloor.multifunction

    public static func artifact(for platform: ModelPlatform) -> String {
        variant.artifact(for: platform)
    }
}
