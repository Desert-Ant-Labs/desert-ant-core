import DesertAnt

/// A published precision of the who model. On Apple platforms its Core ML graphs and sidecars sit on the Hub
/// under `coreml-<rawValue>`, a compiled program a graph; the other platforms run the LiteRT graphs, published
/// at one precision, int8, under `litert-int8`, as five signatures of one file.
public enum ModelVariant: String, Sendable, Equatable, CaseIterable, Identifiable {
    /// Weights as float16 in the Core ML graphs. The default on Apple platforms; not published for the others.
    case fp16
    /// Weights as 8-bit integers: half the download on Apple platforms, the one precision elsewhere.
    case int8

    public var id: String { rawValue }

    /// The precision a platform runs unless asked otherwise: `fp16` with Core ML, `int8` with LiteRT.
    public static var `default`: ModelVariant { ModelPlatform.current == .apple ? .fp16 : .int8 }

    /// Whether the Hub carries this precision for a platform.
    public func isAvailable(on platform: ModelPlatform) -> Bool { platform == .apple || self == .int8 }

    /// The graphs every variant directory holds: an encoder and a query graph per window, named by the
    /// window's 10 ms frames, so 60 s and 300 s, and the voice graph that joins the pieces, named by its
    /// window's filterbank frames.
    public static let graphs = ["encoder_6000", "queries_6000", "encoder_30000", "queries_30000", "voice_3256"]

    /// The directory on the Hub a platform reads this variant from: `coreml-fp16` or `coreml-int8` on Apple
    /// platforms, the one LiteRT directory elsewhere.
    public func directory(for platform: ModelPlatform) -> String {
        platform == .apple ? "coreml-\(rawValue)" : "litert-int8"
    }

    /// The one LiteRT file off Apple platforms: every graph a signature of it, named as `graphs`.
    public static let liteRT = "who.tflite"

    /// A graph's file for a platform, relative to the repo root: its compiled Core ML program on Apple
    /// platforms, the one LiteRT file elsewhere.
    public func file(_ graph: String, for platform: ModelPlatform) -> String {
        "\(directory(for: platform))/" + (platform == .apple ? "\(graph).mlmodelc" : Self.liteRT)
    }

    /// A graph's file on this platform.
    public func compiled(_ graph: String) -> String { file(graph, for: .current) }

    /// The artifact `isAvailable` and the smoke tests look for.
    public func artifact(for platform: ModelPlatform) -> String { file(Self.graphs[0], for: platform) }

    /// Repo-relative entries each platform needs for this variant: the five Core ML programs on Apple
    /// platforms, the one LiteRT file elsewhere, and the four sidecars, for the platforms the precision is
    /// published for.
    public var files: [ModelPlatform: [String]] {
        Dictionary(uniqueKeysWithValues: ModelPlatform.allCases.filter { isAvailable(on: $0) }.map { platform in
            let sidecars = [WhoModel.meta, WhoModel.melBanks, WhoModel.voiceBanks, WhoModel.embedding].map { "\(directory(for: platform))/\($0)" }
            let models = platform == .apple ? Self.graphs.map { file($0, for: platform) + "/" } : [artifact(for: platform)]
            return (platform, models + sidecars)
        })
    }

    /// This variant's files at the catalog's pinned revision, so choosing one precision never downloads the other.
    public var distribution: ModelDistribution { distribution(revision: WhoModel.revision) }

    /// The same at an explicit repo `revision` (a tag, a branch or a commit hash). Each revision caches separately.
    public func distribution(revision: String) -> ModelDistribution {
        ModelDistribution(repo: WhoModel.repo, revision: revision, files: files, runtimeFiles: [:])
    }
}
