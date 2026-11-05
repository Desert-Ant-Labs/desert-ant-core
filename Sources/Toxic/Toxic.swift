import DesertAnt

/// The eleven heads: what a text does, and who a hateful text targets.
public enum Label: String, Sendable, Hashable, Codable, CaseIterable {
    /// Incitement to hatred or violence against a group.
    case hateful = "HATEFUL"
    /// Insulting or degrading language, aimed or not.
    case abusive = "ABUSIVE"
    /// A threat of violence.
    case threat = "THREAT"
    case race = "RACE"
    case religion = "RELIGION"
    case nationalOrEthnicOrigin = "NATIONAL_ETHNIC_ORIGIN"
    case sexualOrientation = "SEXUAL_ORIENTATION"
    case gender = "GENDER"
    case disability = "DISABILITY"
    case age = "AGE"
    case other = "OTHER"

    /// The three heads that say what a text does.
    public static let content: [Label] = [.hateful, .abusive, .threat]
    /// The eight heads that say which group a hateful text is about.
    public static let targets: [Label] = [.race, .religion, .nationalOrEthnicOrigin, .sexualOrientation, .gender, .disability, .age, .other]

    /// Whether this head names a target group.
    public var isTarget: Bool { Label.content.contains(self) == false }
}

/// Options for one ``Toxic/analyze(_:options:)`` call.
public struct Options: Sendable {
    /// Thresholds that replace the model's defaults for the heads named; a head at or above its threshold is
    /// flagged. The defaults come with the model and every ``Analysis`` carries the thresholds it was judged at.
    public var thresholds: [Label: Double]

    public init(thresholds: [Label: Double] = [:]) {
        self.thresholds = thresholds.filter { $0.value.isFinite }
    }
}

/// The result of analyzing one text.
public struct Analysis: Sendable, Hashable {
    /// Every head's probability in `0...1`.
    public let scores: [Label: Double]
    /// The threshold each head was judged at.
    public let thresholds: [Label: Double]
    /// The heads at or above their thresholds, content and target heads alike.
    public let flagged: Set<Label>

    /// Whether any content head fired: the text is hateful, abusive or threatening at the thresholds.
    public var isToxic: Bool { Label.content.contains(where: flagged.contains) }
    /// The content heads that fired, in ``Label/content`` order.
    public var content: [Label] { Label.content.filter(flagged.contains) }
    /// The target heads that fired, highest score first. Meaningful when ``Label/hateful`` fired.
    public var targets: [Label] {
        Label.targets.filter(flagged.contains).sorted { (scores[$0] ?? 0) > (scores[$1] ?? 0) }
    }

    /// One head's probability.
    public func score(_ label: Label) -> Double { scores[label] ?? 0 }

    public init(scores: [Label: Double], thresholds: [Label: Double]) {
        self.scores = scores
        self.thresholds = thresholds
        flagged = Set(scores.filter { $0.value >= (thresholds[$0.key] ?? 0.5) }.keys)
    }
}

/// Errors thrown while loading or running the model.
public enum ToxicError: MessageError, Sendable {
    /// A model file could not be found or read.
    case resourceMissing
    /// The files on disk are not a model this SDK reads.
    case invalidModel(String)
    /// On-device inference failed or returned an unexpected output.
    case predictionFailed(String)

    public var message: String {
        switch self {
        case .resourceMissing: "A Toxic model resource was not found."
        case .invalidModel(let detail): "Invalid Toxic model: \(detail)."
        case .predictionFailed(let detail): "On-device hate-speech triage failed: \(detail)."
        }
    }
}

/// On-device hate-speech triage.
///
/// Scores a text for hate, abuse and threats, and for the group a hateful text targets, entirely on the device:
/// Core ML on Apple platforms, LiteRT everywhere else. Create one and reuse it.
///
/// ```swift
/// let toxic = Toxic()
/// let result = try await toxic.analyze(comment)
/// if result.isToxic { holdForReview(result.content, result.targets) }
/// result.score(.hateful)    // 0...1
/// ```
///
/// A text longer than the model's window is read in overlapping windows, and each head keeps its highest score.
public final class Toxic: @unchecked Sendable {
    private let model: LoadedModel<Model>

    /// Creates a classifier. Construction does no work; the model loads on the first ``analyze(_:options:)`` or
    /// ``download(progress:)``.
    ///
    /// `directory` is where the model lives. If it already holds the model it is used offline; otherwise the
    /// model is downloaded into it. With no `directory`, a managed cache location is used. The graph runs whole
    /// on the Neural Engine, hence the `computeUnits` default; `.all` lets Core ML place it on the GPU, which is
    /// slower here.
    public convenience init(directory: String? = nil, computeUnits: ComputeUnits = .cpuAndNeuralEngine) {
        self.init(directory: directory, cacheRoot: nil, computeUnits: computeUnits)
    }

    /// Binding entry point that also supplies the platform base cache root.
    @_spi(ToxicBindings)
    public init(directory: String?, cacheRoot: String?, computeUnits: ComputeUnits = .cpuAndNeuralEngine) {
        model = LoadedModel(ToxicModel.self, directory: directory, cacheRoot: cacheRoot) { files in
            try Model(assets: try await .toxic(files: files, computeUnits: computeUnits))
        }
    }

    /// Creates a classifier from explicitly provided assets (the wasm self-hosted and custom-deployment paths).
    @_spi(ToxicBindings)
    public init(assets: ModelAssets) {
        model = LoadedModel { try Model(assets: assets) }
    }

    /// Whether the model is available with no network.
    public func isDownloaded() -> Bool { model.isDownloaded() }

    /// Whether the model is on disk for a given location, before one is built.
    public static func isDownloaded(directory: String? = nil, cacheRoot: String? = nil) -> Bool {
        ToxicModel.isAvailable(directory: directory, cacheRoot: cacheRoot)
    }

    /// Download and load the model ahead of time, reporting progress `0...1`. A no-op once loaded.
    public func download(progress: @Sendable @escaping (Double) -> Void = { _ in }) async throws {
        try await model.download(progress: progress)
    }

    /// Await model readiness, so the bindings can surface load errors eagerly.
    @_spi(ToxicBindings)
    public func waitUntilLoaded() async throws {
        _ = try await model.value()
    }

    /// The thresholds the model ships with, one per head, chosen on validation text. Every ``Analysis`` carries the
    /// thresholds it was judged at, so an app reads them from its first result; this is for the bindings' tests.
    @_spi(ToxicBindings)
    public func defaultThresholds() async throws -> [Label: Double] {
        try await model.value().defaultThresholds
    }

    /// Score a text. Throws `CancellationError` promptly if the calling task is cancelled.
    public func analyze(_ text: String, options: Options = .init()) async throws -> Analysis {
        try Task.checkCancellation()
        let model = try await model.value()
        try Task.checkCancellation()
        let scores = try await model.scores(for: text)
        return Analysis(scores: scores, thresholds: model.defaultThresholds.merging(options.thresholds) { _, override in override })
    }

    /// The built pipeline, for the tests that feed the graph one window.
    func loadedModel() async throws -> Model { try await model.value() }
}
