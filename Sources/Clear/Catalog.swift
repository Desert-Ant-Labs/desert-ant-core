import DesertAnt

/// The clear model: on-device speech enhancement (DeepFilterNet3).
public enum ClearModel: ModelDeclaration {
    public static let id = "clear"
    public static let product = "Clear"
    public static let revision = "v0.3.0"
    public static let sdkVersion = "3.5.0"
    public static let summary = "On-device speech enhancement: denoise, dereverb, and loudness-normalize."

    /// The SDK default. The repo also publishes `clear-natural`, which a caller
    /// selects with `Clear(variant:)` and which downloads through ``ModelVariant``:
    /// tooling and the shared test fixture expect the catalog entry to describe
    /// one default artifact.
    public static let variant = ModelVariant.default
    /// Core ML export (a directory on the Hub): Apple. Already ANE-friendly and
    /// 6-bit palettized, so no per-platform export shaping is needed.
    public static let coreML = variant.coreML
    /// LiteRT export: Android/Linux/Windows, and LiteRT.js on the web.
    public static let tflite = variant.tflite

    /// No sidecars: the DSP front end (`DSP.swift`/`Features.swift`) carries the
    /// constants that would otherwise be a metadata file.
    public static let files: [ModelPlatform: [String]] = variant.files
    /// Core AI export: preferred on iOS 27 and macOS 27, with `files` as the fallback.
    public static let coreAI = variant.coreAI
    public static let runtimeFiles: [ModelRuntime: [String]] = variant.runtimeFiles

    public static func artifact(for platform: ModelPlatform) -> String {
        variant.artifact(for: platform)
    }
}
