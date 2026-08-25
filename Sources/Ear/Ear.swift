import DesertAnt

/// A candidate language and how likely the detector thinks it is.
public struct LanguagePrediction: Sendable, Equatable, Identifiable {
    public var id: String { language }
    /// ISO 639-1 where one exists, otherwise 639-3.
    public let language: String
    /// `0...1`, averaged over the windows that were listened to.
    public let probability: Double
}

/// What the detector heard.
public struct Detection: Sendable, Equatable {
    /// Candidates, most likely first.
    public let candidates: [LanguagePrediction]
    /// How many windows of audio the answer is averaged over.
    public let windows: Int

    /// The detected language, or nil if there was nothing to listen to.
    public var language: String? { candidates.first?.language }
    /// The detected language's probability, `0...1`.
    public var confidence: Double { candidates.first?.probability ?? 0 }

    /// Whether this answer is worth routing work on.
    ///
    /// False when the top two candidates are too close to separate, and false
    /// for the Nordic languages, which the detector confuses with each other
    /// confidently rather than uncertainly - so their probability does not
    /// reveal the problem and a margin test cannot catch it.
    public var isReliable: Bool {
        guard let top = candidates.first else { return false }
        if confusableLanguages.contains(top.language) { return false }
        let runnerUp = candidates.count > 1 ? candidates[1].probability : 0
        return top.probability - runnerUp >= Detection.reliableMargin
    }

    /// How far ahead the top candidate must be before the answer is worth
    /// routing on.
    ///
    /// Calibrated on 162 recordings - 49 YouTube uploads and 113 continuous
    /// parliamentary recordings - by sweeping the threshold against routing
    /// accuracy:
    ///
    /// | margin | answered | of those, correct |
    /// |--------|----------|-------------------|
    /// | 0.00   | 100%     | 93.2%             |
    /// | 0.15   | 89.5%    | 95.2%             |
    /// | 0.25   | 80.9%    | 98.5%             |
    /// | 0.80   | 63.6%    | 100%              |
    ///
    /// 0.25 is where precision reaches 98.5% while still answering four files
    /// in five, and on files in a language the product actually offers it is
    /// 100% correct at 85.9% coverage. Raising it to 0.80 buys the last 1.5
    /// points by declining a fifth of the corpus, which is a worse trade for a
    /// caller who has to do something with the remainder.
    public static let reliableMargin = 0.25
}

/// Errors thrown while loading or running the model.
public enum EarError: MessageError, Sendable {
    case modelNotFound
    case invalidModel(String)
    case invalidAudio(String)
    case predictionFailed

    public var message: String {
        switch self {
        case .modelNotFound: "An Ear model resource was not found."
        case .invalidModel(let detail): "Invalid Ear model: \(detail)."
        case .invalidAudio(let detail): "Invalid audio: \(detail)."
        case .predictionFailed: "On-device language identification failed."
        }
    }
}

/// On-device spoken language identification.
///
/// Names the language of a recording, so an app can pick the right recognizer
/// before it starts transcribing. Runs on the Neural Engine on Apple platforms
/// and through LiteRT everywhere else.
///
/// ```swift
/// let ear = Ear()
/// let detection = try await ear.identify(contentsOf: url)
/// detection.language     // "pt"
/// detection.confidence   // 0.91
/// ```
///
/// Create one and reuse it. Construction does no work and starts no download;
/// the model loads on the first ``identify(samples:sampleRate:windows:)`` or
/// ``download(progress:)``, off your calling thread.
///
/// `directory` is where the model lives. If it already contains the model (you
/// pre-downloaded or shipped it there) it is used offline; otherwise the model
/// is downloaded into it and reused offline afterwards. With no `directory` a
/// managed cache location is used. Nothing is bundled with this package.
public final class Ear: @unchecked Sendable {
    // Resolving the files, loading once, sharing that load and reporting
    // availability are the same for every model, so they live in the core's
    // `LoadedModel`; Ear adds only how a resolved directory becomes its model.
    private let model: LoadedModel<Model>

    /// How many windows are listened to when the caller does not say.
    ///
    /// Measured, and the honest answer is that it barely matters. Across 162
    /// recordings, one window and six windows both misroute 11 files; every
    /// count between them lands on 11 to 14. Averaging does not help because a
    /// file is one speaker in one room, so when the detector is wrong it is
    /// wrong in every window of that file - the errors are unanimous, not
    /// independent, and there is nothing for an average to cancel.
    ///
    /// Three is kept because it costs about 45 ms in total on the Neural
    /// Engine and covers the one case a single window cannot: a recording whose
    /// opening is music or titles. Windows are spread across the file rather
    /// than taken consecutively for the same reason.
    ///
    /// Each window is thirty seconds because that is the detector's context.
    /// A shorter one is padded with silence and wastes most of the encoder:
    /// 10 s windows score 87.6% per file against 92.3% for 30 s.
    public static let defaultWindows = 3

    public convenience init(directory: String? = nil) {
        self.init(directory: directory, cacheRoot: nil)
    }

    public init(directory: String?, cacheRoot: String?) {
        model = LoadedModel(EarModel.self, directory: directory, cacheRoot: cacheRoot) {
            try await Model(assets: .ear(files: $0))
        }
    }

    /// Creates an identifier from explicitly provided assets, for the wasm and
    /// JNI paths where the host resolved the files itself.
    @_spi(EarBindings)
    public init(assets: ModelAssets) throws {
        let built = try Model(assets: assets)
        model = LoadedModel { built }
    }

    /// Whether this identifier's model is present, so a caller can decide
    /// whether to show a download step.
    public func isDownloaded() -> Bool { model.isDownloaded() }

    /// Whether the model is on disk for a given location, before one is built.
    public static func isDownloaded(directory: String? = nil, cacheRoot: String? = nil) -> Bool {
        EarModel.isAvailable(directory: directory, cacheRoot: cacheRoot)
    }

    /// Fetch and prepare the model without identifying anything.
    public func download(
        progress: @Sendable @escaping (Double) -> Void = { _ in }
    ) async throws {
        try await model.download(progress: progress)
    }

    /// Identify the language of mono samples.
    ///
    /// `sampleRate` is the rate of `samples`; audio at another rate is
    /// resampled. `windows` is how many thirty-second windows to listen to,
    /// spread across the recording rather than taken from the front, because
    /// the opening of a file is titles and music. Fewer are used when the audio
    /// is shorter than that.
    public func identify(
        samples: [Float],
        sampleRate: Double,
        windows: Int = Ear.defaultWindows
    ) async throws -> Detection {
        guard !samples.isEmpty else { throw EarError.invalidAudio("no samples") }
        guard windows > 0 else { throw EarError.invalidAudio("windows must be at least 1") }
        return try await model.value().identify(samples: samples, sampleRate: sampleRate,
                                                windows: windows)
    }

    /// The languages this model can name, as ISO codes.
    public func supportedLanguages() async throws -> [String] {
        try await model.value().languages.map(canonicalLanguage)
    }

    /// The rate the model expects, so the file path can decode straight to it.
    func modelSampleRate() async throws -> Double {
        Double(try await model.value().sampleRate)
    }
}
