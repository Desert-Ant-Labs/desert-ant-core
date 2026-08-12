// Which published export of the model to run.
//
// The Hub repo ships two trained variants side by side, so this is a real
// choice, not a label: it selects the files that get downloaded and loaded.
// `Result.modelVariant` reports the one that produced a given output, which is
// what makes a benchmark or a usage event self-identifying.

import DesertAnt

/// A published variant of the clear model. Its `rawValue` is the artifact stem
/// on the Hub (`clear-studio.mlmodelc`, `clear-studio.tflite`, ...), so a
/// persisted selection and a telemetry field are the same string.
public enum ModelVariant: String, Sendable, Equatable, CaseIterable, Identifiable {
    /// Studio: the more aggressive denoise/dereverb. The SDK default.
    case clearStudio = "clear-studio"
    /// Natural: lighter touch, keeps more of the room.
    case clearNatural = "clear-natural"

    public var id: String { rawValue }

    /// The variant a `Clear` uses unless told otherwise.
    public static let `default` = ModelVariant.clearStudio

    public var displayName: String {
        switch self {
        case .clearStudio: "clear-studio"
        case .clearNatural: "clear-natural"
        }
    }

    /// Core ML export (a directory on the Hub): Apple.
    public var coreML: String { "\(rawValue).mlmodelc" }
    /// LiteRT export: Android/Linux/Windows, and LiteRT.js on the web.
    public var tflite: String { "\(rawValue).tflite" }

    /// The runnable artifact for `platform`.
    public func artifact(for platform: ModelPlatform) -> String {
        platform == .apple ? coreML : tflite
    }

    /// The artifact for the platform being built for.
    public var artifact: String { artifact(for: .current) }

    /// Repo-relative entries each platform needs for this variant. Clear has no
    /// sidecars (the DSP front end carries what would be a metadata file), so a
    /// platform ships exactly one artifact.
    public var files: [ModelPlatform: [String]] {
        [
            .apple: [coreML + "/"],
            .android: [tflite],
            .linux: [tflite],
            .windows: [tflite],
            .web: [tflite],
        ]
    }

    /// This variant's slice of the model repo: the same repo and pinned
    /// revision as the catalog entry, but only this variant's files, so
    /// choosing one variant never downloads the other.
    public var distribution: ModelDistribution { distribution(revision: ClearModel.revision) }

    /// The same slice pinned to an explicit repo `revision` (a tag like
    /// `v0.2.0`, a branch, or a commit hash) instead of the SDK's pinned one.
    /// Each revision caches separately, so switching never clobbers another.
    public func distribution(revision: String) -> ModelDistribution {
        ModelDistribution(repo: ClearModel.repo, revision: revision, files: files)
    }

    /// The variant an artifact path belongs to, by its file name
    /// (`.../clear-natural.mlmodelc` -> `.clearNatural`), or nil if the name is
    /// not a published variant - a custom or renamed export.
    public static func inferred(fromPath path: String) -> ModelVariant? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return allCases.first { name.hasPrefix($0.rawValue) }
    }
}
