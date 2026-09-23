import DesertAnt

/// The ear model: on-device spoken language identification.
///
/// Every platform runs the same graph shape (log-mel in, language logits out)
/// because the frontend is Swift rather than part of the artifact; see
/// `Frontend.swift` for why.
public enum EarModel: ModelDeclaration {
    public static let id = "ear"
    public static let product = "Ear"
    public static let revision = "v0.1.0"
    public static let sdkVersion = "3.5.0"
    public static let summary = "On-device spoken language identification across 99 languages."

    /// Artifact names describe roles rather than the network behind them, so
    /// replacing the detector is a new upload rather than an SDK change.
    ///
    /// The Apple artifact is a compiled Core ML program, not an `.mlpackage`.
    /// Core ML keys its specialized Neural Engine program cache on the compiled
    /// model's path, so an `.mlpackage` recompiles into a fresh temporary
    /// directory on every launch and never hits that cache.
    public static let coreML = "ear.mlmodelc"
    public static let liteRT = "ear.tflite"

    /// Sidecars: the language codes in head order, the geometry the frontend
    /// refuses to hardcode, and the mel filterbank. The filterbank ships as a
    /// table rather than being rebuilt in Swift because the reference filters
    /// are slaney-normalized librosa output, and reimplementing that is a source
    /// of silent drift for the sake of 64 KB.
    public static let languages = "languages.json"
    public static let meta = "ear_meta.json"
    public static let melFilters = "mel_filters.f32"

    private static let sidecars = [languages, meta, melFilters]

    public static let files: [ModelPlatform: [String]] = [
        .apple: [coreML + "/"] + sidecars,
        .android: [liteRT] + sidecars,
        .linux: [liteRT] + sidecars,
        .windows: [liteRT] + sidecars,
        .web: [liteRT] + sidecars,
    ]

    public static func artifact(for platform: ModelPlatform) -> String {
        platform == .apple ? coreML : liteRT
    }
}
