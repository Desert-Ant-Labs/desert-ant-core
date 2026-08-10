#if canImport(Foundation) && !os(Android) && !os(WASI)
import Foundation
#endif
import DesertAnt
import AudioDSP
import AudioIO

/// `Uhm` — public API for filler-word detection: frame-precise "uh", "um",
/// "hmm" and other filler sounds, one prediction every 20 ms. DistilHuBERT
/// under the hood, running through desert-ant-core's inference seam (Core ML
/// on Apple today).
///
/// The model is downloaded on demand from `desert-ant-labs/uhm` and cached
/// locally. Construction is cheap and does no I/O; the model downloads (if
/// needed) and loads on the first `analyze(...)`. Call `download(progress:)`
/// to prewarm.
///
/// Usage:
/// ```
/// let uhm = Uhm()
/// let result = try await uhm.analyze(audioPath: "in.wav")
/// for f in result.fillers { print(f.start, f.end, f.type ?? "") }
/// ```
///
/// Trained on English; transfers acoustically to Spanish, French, German, and
/// Dutch without retraining.
public final class Uhm: @unchecked Sendable {

    // MARK: - Types

    /// Precision / recall trade-off knob. `balanced` is the default — empirically
    /// the cleanest cutoff between real fillers and borderline false positives
    /// across en/es/fr/de/nl. Step up to `.precision` for stricter auto-cut, or
    /// down to `.recall` when you'd rather review-and-confirm than miss.
    public enum Bias: Sendable {
        // Thresholds are stable across model versions: shipped models are
        // pre-calibrated so a given `Options.minConfidence` means the same thing
        // against any release.
        /// Strictest gate (min confidence 0.75) — fewest false alarms; safest for automatic cuts.
        case precision
        /// Default gate (min confidence 0.65) — clean cuts on the labeled corpus.
        case balanced
        /// Loosest gate (min confidence 0.50) — catches more, at the cost of more false positives.
        case recall

        /// The confidence threshold this preset maps to. Public so host apps can
        /// reuse a preset's value directly (e.g. gate an edit action at
        /// `Bias.precision.minConfidence`) instead of hardcoding the number.
        public var minConfidence: Double {
            switch self {
            case .precision: return 0.75
            case .balanced: return 0.65
            case .recall: return 0.50
            }
        }
    }

    /// Tuning for a single `analyze(...)` call.
    public struct Options: Sendable {
        /// Precision/recall preset that sets the confidence threshold. Default `.balanced`.
        public var bias: Bias
        /// Whether to run the type labeler to fill in `Detection.type`
        /// (`uh`/`um`/`hmm`/…). Set `false` to skip it when you only need
        /// filler-vs-not spans. Default `true`. Apple platforms only
        /// (SoundAnalysis); elsewhere `type` stays nil.
        public var includeTypes: Bool
        /// Override the bias preset's confidence threshold. `nil` = use `bias`.
        public var minConfidence: Double?
        /// Discard detections shorter than this, in seconds. Default `0.12`.
        public var minDurationSec: Double

        /// Creates analysis options.
        /// - Parameters:
        ///   - bias: Precision/recall preset. Default `.balanced`.
        ///   - includeTypes: Run the type labeler. Default `true`.
        ///   - minConfidence: Explicit threshold that overrides `bias`. Default `nil`.
        ///   - minDurationSec: Minimum detection duration to keep. Default `0.12`.
        public init(bias: Bias = .balanced,
                    includeTypes: Bool = true,
                    minConfidence: Double? = nil,
                    minDurationSec: Double = 0.12) {
            self.bias = bias
            self.includeTypes = includeTypes
            self.minConfidence = minConfidence
            self.minDurationSec = minDurationSec
        }

        /// The default options (`.balanced`, types on, 0.12 s minimum).
        public static let `default` = Options()
    }

    /// Output of the per-filler type labeler.
    /// `and` is a mid-sentence "and"-as-filler subtype — useful when you want
    /// to keep or treat connectors differently from `uh`/`um`. `other` is the
    /// "labeler isn't confident which kind" bucket — surface it as something
    /// neutral ("filler") in user-facing UI; useful as-is for analytics.
    public enum FillerType: String, Sendable, Codable, CaseIterable {
        case uh, um, hmm, and, other
    }

    /// A single detected filler span.
    public struct Detection: Sendable, Equatable {
        /// Start time in seconds from the beginning of the audio.
        public let start: Double
        /// End time in seconds from the beginning of the audio.
        public let end: Double
        /// Model confidence for this span, in `0...1`.
        public let confidence: Double
        /// The filler subtype, or `nil` when `includeTypes` is false or the type labeler couldn't load.
        public let type: FillerType?
        /// Span length in seconds (`end - start`).
        public var duration: Double { end - start }

        /// Creates a detection. Normally you receive these from `analyze(...)`
        /// rather than constructing them, but the initializer is public for
        /// tests and for feeding `reconcileWords(_:fillers:)`.
        public init(start: Double, end: Double, confidence: Double, type: FillerType?) {
            self.start = start
            self.end = end
            self.confidence = confidence
            self.type = type
        }
    }

    /// Per-phase wall-time captured during `analyze()`. `inferenceSec` is
    /// the sum of every model call (the bit the accelerator touches); the
    /// rest is Swift glue. Use it to tell whether you're CPU-bound on
    /// decode/labeling or actually waiting on the model.
    public struct PhaseTimings: Sendable {
        /// Audio file → 16 kHz mono Float32. One pass over the audio.
        public var decodeSec: Double
        /// Cumulative model-inference time inside the frame detector. This is
        /// the number that moves when you pin compute units.
        public var inferenceSec: Double
        /// Per-window normalize + input build.
        public var prepSec: Double
        /// Threshold + run merging on frame probs.
        public var groupSec: Double
        /// Type-labeler classifier across all detections (small
        /// model, mostly CPU; usually a few ms total).
        public var labelingSec: Double

        /// Creates a phase-timing record. Populated by `analyze(...)`; the
        /// initializer is public mainly for constructing `Result` values in tests.
        public init(decodeSec: Double = 0,
                    inferenceSec: Double = 0,
                    prepSec: Double = 0,
                    groupSec: Double = 0,
                    labelingSec: Double = 0) {
            self.decodeSec = decodeSec
            self.inferenceSec = inferenceSec
            self.prepSec = prepSec
            self.groupSec = groupSec
            self.labelingSec = labelingSec
        }
    }

    /// The result of an `analyze(...)` call.
    public struct Result: Sendable {
        /// Detected fillers, in time order.
        public let fillers: [Detection]
        /// Total decoded audio length, in seconds.
        public let audioDuration: Double
        /// Per-phase breakdown of the `analyze(...)` call this `Result` came from.
        public let phaseTimings: PhaseTimings

        /// Creates a result. You normally receive this from `analyze(...)`.
        public init(fillers: [Detection], audioDuration: Double, phaseTimings: PhaseTimings = PhaseTimings()) {
            self.fillers = fillers
            self.audioDuration = audioDuration
            self.phaseTimings = phaseTimings
        }
    }

    // MARK: - State

    /// Model input rate: 16 kHz mono, one frame every 20 ms.
    static let sampleRate = 16_000

    // Resolving, downloading, single-flighting, and offline availability are
    // `LoadedModel`; Uhm adds only how a resolved directory becomes its session.
    let model: LoadedModel<ModelAssets>

    /// The concrete model tier this instance loads (`auto` already resolved),
    /// or nil when it was built from explicit assets or a model path whose
    /// tier could not be inferred - only the caller knows what that file is.
    public let resolvedQuality: Quality?

    // MARK: - Init

    /// Creates an analyzer.
    ///
    /// Construction does **no** network or model I/O. The model is downloaded
    /// (if not already cached) and loaded lazily on the first `analyze(...)`.
    /// To fetch it ahead of time — e.g. at app launch — call
    /// `download(progress:)`.
    ///
    /// Nothing is bundled with this package. To ship the model with your app,
    /// point `directory` at a folder you populated with the model files: it is
    /// used as-is, offline, and nothing is downloaded.
    ///
    /// - Parameters:
    ///   - directory: An explicit model home (adopt files there, else download
    ///     into it), or `nil` for the managed cache.
    ///   - quality: Which model tier to load. Default `.auto` (see ``Quality``).
    ///   - computeUnits: Core ML compute-unit policy. Default `.all`.
    public convenience init(directory: String? = nil, quality: Quality = .auto,
                            computeUnits: ComputeUnits = .all) {
        self.init(directory: directory, cacheRoot: nil, quality: quality,
                  computeUnits: computeUnits)
    }

    /// Binding entry point that also supplies the platform base cache root under
    /// which the managed layout lives. On Apple/Linux FileManager provides it,
    /// so the public `init(directory:...)` passes `nil`.
    @_spi(UhmBindings)
    public init(directory: String?, cacheRoot: String?, quality: Quality = .auto,
                computeUnits: ComputeUnits = .all) {
        // A tier is its own slice of the model repo, so the loader resolves
        // that distribution rather than the catalog entry's default one.
        let resolved = quality.resolved
        resolvedQuality = resolved
        model = LoadedModel(resolved.distribution,
                            directory: directory, cacheRoot: cacheRoot) { files in
            try await .uhm(files: files, quality: resolved, computeUnits: computeUnits)
        }
    }

    /// Creates a detector from explicitly provided assets (the bindings and
    /// custom-deployment paths).
    @_spi(UhmBindings)
    public init(assets: ModelAssets) {
        resolvedQuality = nil
        model = LoadedModel { assets }
    }

    /// Bench / power-user initializer — load a local model artifact directly
    /// (a `.mlmodelc` on Apple), skipping the store entirely. Lets a host app
    /// ship its own variant. For tests and custom deployments; apps point
    /// `directory` at their files instead. The tier is read off the file name
    /// when it matches a published one (`uhm.*`).
    public init(modelPath: String, computeUnits: ComputeUnits = .all) throws {
        let assets = try ModelAssets(modelPath: modelPath, computeUnits: computeUnits)
        resolvedQuality = Quality.inferred(fromPath: modelPath)
        model = LoadedModel { assets }
    }

    /// Whether a given tier is already downloaded and intact (usable offline),
    /// without constructing an analyzer. `directory` mirrors the initializer's
    /// parameter (nil = the managed cache).
    public static func isDownloaded(quality: Quality = .auto,
                                    directory: String? = nil,
                                    cacheRoot: String? = nil) -> Bool {
        quality.resolved.distribution
            .isAvailable(cacheDirectory: directory, cacheRoot: cacheRoot)
    }

    // MARK: - Model management

    /// Whether the model is already downloaded and available with no network:
    /// cached (for the managed location) or already present in `directory`.
    /// Checked on disk, so it's safe to read on launch to decide whether to
    /// show a download UI before calling `download(progress:)`.
    public func isDownloaded() -> Bool { model.isDownloaded() }

    /// Download and cache the model without running anything.
    ///
    /// Call this at app launch (or behind a Wi-Fi/"prepare" gate) to prewarm
    /// the on-device model so the first real `analyze(...)` is instant. Safe to
    /// call repeatedly: once cached it's a cheap no-op. Concurrent calls, and
    /// an implicit load from a first use, share one download.
    ///
    /// - Parameter progress: Download progress in `0...1`.
    public func download(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await model.download(progress: progress)
    }

    /// Await model readiness. The bindings use this to surface load errors
    /// eagerly; apps can just call `analyze`.
    @_spi(UhmBindings)
    public func waitUntilLoaded() async throws {
        _ = try await model.value()
    }

    // MARK: - Analyze

    /// Detects filler words in raw PCM samples.
    ///
    /// - Parameters:
    ///   - samples: Mono PCM samples. Resampled to 16 kHz internally if needed.
    ///   - sampleRate: Sample rate of `samples`, in Hz.
    ///   - options: Bias, type labeling, and duration thresholds. Default `.default`.
    ///   - progressHandler: Optional inference progress in `0...1`.
    /// - Returns: The detected fillers plus timing metadata.
    /// - Throws: A model error, or `CancellationError` if the enclosing task is cancelled.
    public func analyze(
        samples: [Float],
        sampleRate: Int,
        options: Options = .default,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Result {
        try await analyze(samples: samples, sampleRate: sampleRate, options: options,
                          progressHandler: progressHandler, timings: PhaseTimings())
    }

    private func analyze(
        samples: [Float],
        sampleRate: Int,
        options: Options,
        progressHandler: (@Sendable (Double) -> Void)?,
        timings: PhaseTimings
    ) async throws -> Result {
        var timings = timings
        // Bail early if the caller already cancelled.
        try Task.checkCancellation()
        // Download (first call only) + load the model. No-op once cached/loaded.
        let assets = try await model.value()

        let input = sampleRate == Self.sampleRate
            ? samples
            : Resample.linear(samples, from: Double(sampleRate), to: Double(Self.sampleRate))
        let audioDuration = Double(input.count) / Double(Self.sampleRate)
        let minConf = options.minConfidence ?? options.bias.minConfidence

        let detector = FillerDetector(session: assets.session)
        var detTimings = FillerDetector.Timings()
        var detections = try await detector.detect(
            samples: input,
            progressHandler: progressHandler,
            timingsHandler: { detTimings = $0 }
        )
        .filter { $0.confidence >= minConf && $0.duration >= options.minDurationSec }
        .map { Detection(start: $0.start, end: $0.end, confidence: $0.confidence, type: nil) }
        timings.inferenceSec = detTimings.inferenceSec
        timings.prepSec = detTimings.prepSec
        timings.groupSec = detTimings.groupSec

        if options.includeTypes {
            let labelStart = ContinuousClock.now
            detections = try await labelDetections(detections, samples: input, assets: assets)
            timings.labelingSec = elapsedSeconds(since: labelStart)
        }

        return Result(fillers: detections, audioDuration: audioDuration, phaseTimings: timings)
    }

    /// Detects filler words in in-memory audio-file `bytes` (WAV and the
    /// platform's decodable formats).
    public func analyze(
        bytes: [UInt8],
        options: Options = .default,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Result {
        let decodeStart = ContinuousClock.now
        let samples = try await AudioIO.decode(bytes: bytes, sampleRate: Double(Self.sampleRate))
        return try await analyze(samples: samples, sampleRate: Self.sampleRate, options: options,
                                 progressHandler: progressHandler,
                                 timings: PhaseTimings(decodeSec: elapsedSeconds(since: decodeStart)))
    }

    #if canImport(Foundation) && !os(Android) && !os(WASI)
    /// Detects filler words in an audio file at the given path.
    ///
    /// Any format the platform decoder can read is accepted; audio is decoded
    /// to 16 kHz mono internally. Filesystem platforms (Apple/Linux); on
    /// Android/web use `analyze(bytes:)`.
    ///
    /// - Parameters:
    ///   - audioPath: Filesystem path to the audio file.
    ///   - options: Bias, type labeling, and duration thresholds. Default `.default`.
    ///   - progressHandler: Optional inference progress in `0...1`.
    /// - Returns: The detected fillers plus timing metadata.
    /// - Throws: A decode/model error, or `CancellationError` if the enclosing task is cancelled.
    public func analyze(
        audioPath: String,
        options: Options = .default,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Result {
        let decodeStart = ContinuousClock.now
        let samples = try await AudioIO.decode(path: audioPath, sampleRate: Double(Self.sampleRate))
        return try await analyze(samples: samples, sampleRate: Self.sampleRate, options: options,
                                 progressHandler: progressHandler,
                                 timings: PhaseTimings(decodeSec: elapsedSeconds(since: decodeStart)))
    }

    /// Detects filler words in the audio at the given file URL.
    ///
    /// - Parameters:
    ///   - audioURL: File URL of the audio. Any decodable format.
    ///   - options: Bias, type labeling, and duration thresholds. Default `.default`.
    ///   - progressHandler: Optional inference progress in `0...1`.
    /// - Returns: The detected fillers plus timing metadata.
    public func analyze(
        audioURL: URL,
        options: Options = .default,
        progressHandler: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Result {
        try await analyze(audioPath: audioURL.path, options: options, progressHandler: progressHandler)
    }
    #endif

    func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    // MARK: - Type labeling (Apple only)

    #if canImport(SoundAnalysis) && canImport(CoreML)
    private func labelDetections(_ detections: [Detection], samples: [Float], assets: ModelAssets) async throws -> [Detection] {
        guard !detections.isEmpty,
              let labelerPath = assets.labelerModelPath,
              let labeler = try? FillerTypeClassifier(modelURL: URL(fileURLWithPath: labelerPath))
        else { return detections }
        let window = Self.sampleRate  // 1 s clip centered on each detection
        var out: [Detection] = []
        for d in detections {
            // Bail between detections so cancellation lands promptly when the
            // caller flips away (e.g. a setting change invalidates these fillers).
            try Task.checkCancellation()
            let center = Int((d.start + d.end) / 2 * Double(Self.sampleRate))
            let start = max(0, center - window / 2)
            let end = min(samples.count, start + window)
            var clip = Array(samples[start..<end])
            if clip.count < window {
                clip.append(contentsOf: [Float](repeating: 0, count: window - clip.count))
            }
            // SNAudioFileAnalyzer wants a file, so the 1 s clip round-trips
            // through a temp WAV.
            let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("uhm-label-\(UUID().uuidString).wav")
            try Data(AudioIO.encodeWAV(clip, sampleRate: Self.sampleRate)).write(to: tmpURL)
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            let labels = try labeler.detect(audioPath: tmpURL.path)
            let bestLabel = labels.max(by: { $0.confidence < $1.confidence })
            let type: FillerType? = bestLabel.flatMap { FillerType(rawValue: $0.label) }
            out.append(Detection(start: d.start, end: d.end, confidence: d.confidence, type: type))
        }
        return out
    }
    #else
    private func labelDetections(_ detections: [Detection], samples: [Float], assets: ModelAssets) async throws -> [Detection] {
        detections   // no labeler on this platform; `type` stays nil
    }
    #endif
}

/// Errors thrown while loading or running the model. (`MessageError` is
/// `LocalizedError` wherever Foundation exists, so `localizedDescription`
/// shows `message`.)
public enum UhmError: MessageError, Sendable {
    /// On-device detection failed or returned an unexpected output.
    case inferenceFailed(String)
    /// A model resource could not be found.
    case modelMissing(String)

    public var message: String {
        switch self {
        case .inferenceFailed(let detail): "On-device filler detection failed: \(detail)."
        case .modelMissing(let name): "A Uhm model resource was not found: \(name)."
        }
    }
}

#if os(WASI)
public extension Uhm {
    /// Build from a JS host inference session (the wasm entry point). The host
    /// (supplied to the module at instantiation) must have compiled the model
    /// first.
    @_spi(UhmBindings)
    convenience init() throws {
        self.init(assets: ModelAssets(session: try inferenceSession(sdk: UhmModel.sdkInfo)))
    }
}
#endif
