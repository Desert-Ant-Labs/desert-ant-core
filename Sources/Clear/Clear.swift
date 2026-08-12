#if canImport(Foundation) && !os(Android) && !os(WASI)
import Foundation
#endif
import DesertAnt
import AudioDSP
import AudioIO

/// On-device speech enhancement: denoise, dereverb, and loudness-normalize a
/// noisy recording to a podcast-ready 48 kHz mono file. DeepFilterNet3 under the
/// hood, running on Core ML (Apple), LiteRT (Android/Linux), or the JS
/// host (web) through desert-ant-core, with the DSP shared across all platforms.
///
/// ```swift
/// let clear = try Clear(modelPath: "clear-studio.tflite")  // or download via Clear()
/// let out = try await clear.enhance(path: "in.wav", to: "out.wav")
/// ```
public final class Clear: @unchecked Sendable {

    /// Linear blend between the enhanced output (1.0) and the original (0.0).
    public struct Strength: Sendable, ExpressibleByFloatLiteral {
        public let value: Double
        public init(_ v: Double) { self.value = v.isFinite ? min(1, max(0, v)) : 1 }
        public init(floatLiteral v: Double) { self.init(v) }
        public static let full: Strength = 1.0
        public static let medium: Strength = 0.7
        public static let subtle: Strength = 0.4
    }

    public struct Options: Sendable {
        /// Enhancement blend. Default full.
        public var strength: Strength
        /// Where the output should land loudness-wise. Defaults to the Apple
        /// Podcasts spec; use a ``Clear/LoudnessPreset``, `.targetLUFS(_:)`, or
        /// `.bypass` to leave the model's own level alone.
        public var mastering: Mastering

        public init(strength: Strength = .full, mastering: Mastering = .applePodcasts) {
            self.strength = strength
            self.mastering = mastering
        }

        /// Loudness targets without naming a delivery platform. `targetLUFS` is
        /// required, so `Options()` still means "full strength, Apple Podcasts".
        public init(strength: Strength = .full, targetLUFS: Double?,
                    peakCeilingDBFS: Double = -1.5, maxGainDB: Double = 9) {
            self.strength = strength
            self.mastering = Mastering(
                integratedLUFS: targetLUFS ?? Mastering.applePodcasts.integratedLUFS,
                truePeakDBTP: peakCeilingDBFS,
                enabled: targetLUFS != nil,
                maxLoudnessGainDB: maxGainDB)
        }

        /// The integrated-LUFS target, or nil when mastering is bypassed.
        public var targetLUFS: Double? { mastering.enabled ? mastering.integratedLUFS : nil }

        public static let `default` = Options()
    }

    public struct Result: Sendable {
        public let samples: [Float]         // enhanced, 48 kHz mono
        public let sampleRate: Double
        public let durationSec: Double
        public let processingSec: Double
        public let measuredLUFS: Double?
        /// True peak of the delivered audio in dBFS, by 4x oversampling, or nil
        /// when mastering was bypassed. Measured *after* limiting, so this is
        /// what a caller can assert a delivery spec against - unlike
        /// ``measuredLUFS``, which reports the input.
        public let measuredTruePeakDBFS: Double?
        /// Which published model variant produced this output, or nil when the
        /// artifact is not a published one (a custom export, or a wasm host
        /// that compiled the model itself).
        public let modelVariant: ModelVariant?
        /// The repo revision the model was resolved from - for a ranged
        /// ``RevisionRequirement`` this is the concrete tag it landed on. Nil
        /// when nothing was downloaded (a local `modelPath`, explicit assets,
        /// or a self-hosted wasm model).
        public let modelRevision: String?
        public var realtimeFactor: Double { processingSec > 0 ? durationSec / processingSec : 0 }
    }

    /// Stages reported through ``ProgressHandler``. Each runs to completion
    /// before the next starts, and `fraction` resets to 0 at every transition,
    /// so a caller can weight them however its UI needs.
    ///
    /// Same cases, and the same order, as the standalone Clear SDK, so progress
    /// code moves over unchanged. What sits behind them differs: that SDK made
    /// two streaming passes over the file (analyze into a loudness meter, then
    /// re-stream applying gain), while this pipeline runs the front end once,
    /// then the model, then masters the result in memory. The split lands in
    /// the same place - a quick analysis phase, then the long model phase.
    public enum Phase: Sendable, Equatable {
        /// Resolving the model: downloading or adopting the files, then
        /// building the platform's session. On Apple the first launch also
        /// pays the Core ML compile, which can take tens of seconds on iPhone;
        /// it is cached afterwards. Skipped entirely once loaded.
        case loadingModel
        /// The DSP front end ahead of the model: resample to 48 kHz, STFT, and
        /// the ERB/DF feature pass. Fast relative to ``enhancing``.
        case analyzing
        /// The model itself, chunk by chunk, plus the strength blend and the
        /// mastering chain that follow it. The long phase: `fraction` is the
        /// share of model chunks finished, reaching 1 once mastering is done.
        case enhancing
    }

    /// A progress report: which ``Phase`` is running and how far into it.
    public struct Progress: Sendable, Equatable {
        public let phase: Phase
        /// 0...1 within `phase`.
        public let fraction: Double
        public init(phase: Phase, fraction: Double) {
            self.phase = phase
            self.fraction = fraction
        }
    }

    /// Called with each ``Progress`` update. Invoked from whatever context the
    /// work is on (model chunks run across a task group), so hop to your own
    /// actor before touching UI state.
    public typealias ProgressHandler = @Sendable (Progress) -> Void

    // Resolving, downloading, single-flighting, and offline availability are
    // `LoadedModel`; Clear adds only how a resolved directory becomes its
    // session pool.
    // `internal` so the Apple streaming path (Streaming.swift) can drive the
    // same loader.
    let model: LoadedModel<ModelAssets>

    /// The variant this instance loads, or nil when it was built from an
    /// explicit artifact/assets whose variant only the caller knows.
    public let variant: ModelVariant?
    /// The revision requirement this instance resolves: `.exact` of the
    /// `revision` passed at init (else the SDK's pinned
    /// ``Clear/modelRevision``), or the range you passed. Nil when the instance
    /// was built from a local `modelPath` or explicit assets (nothing is
    /// downloaded, so no repo revision applies).
    public let revisionRequirement: RevisionRequirement?
    /// The concrete model revision this instance resolves, when it is knowable
    /// without the network: the exact revision, or nil for a ranged
    /// requirement (resolved at load time against the Hub's tags; the loaded
    /// one is reported on ``Result/modelRevision``).
    ///
    /// This is the revision that *will* be downloaded (or that the cache is
    /// checked against - see ``isDownloaded()``). For a branch revision like
    /// `"main"` the cache holds whatever commit was current at download time;
    /// only a tag or commit hash pins the exact contents.
    public var modelRevision: String? { revisionRequirement?.exactRevision }

    /// Default model sessions to run chunks in parallel over. Native LiteRT is
    /// single-threaded per run, so a pool uses multiple cores; Apple (fast) and
    /// wasm (LiteRT.js is already multi-threaded) use one.
    public static var defaultConcurrency: Int {
        #if canImport(CoreML) || os(WASI)
        return 1                                          // Apple: fast single session; wasm: LiteRT.js already threaded
        #elseif os(Android)
        return 2   // cap memory on mobile (about twice the model size)
        #else
        return max(1, min(ProcessInfo.processInfo.activeProcessorCount, 4))   // Linux/Windows desktop/server
        #endif
    }

    /// `computeUnits` selects the Core ML compute units on Apple (ignored by the
    /// LiteRT/JS backends). Default `.all`, letting Core ML place the work
    /// itself; pass `.cpuOnly` if CPU-only benchmarks better for your model
    /// and hardware (the palettized model has run ~2x faster on the CPU than
    /// the Neural Engine or GPU on some M-series Macs).
    /// `concurrency` is the model-session pool size (see `defaultConcurrency`).
    ///
    /// Nothing is bundled with this package. To ship the model with your app,
    /// point `directory` at a folder you populated with the model files: it is
    /// used as-is, offline, and nothing is downloaded.
    ///
    /// `revision` pins a specific published model version (a Hub tag like
    /// `v0.2.0`, a branch, or a commit hash) instead of the revision this SDK
    /// was built against (``Clear/modelRevision``). Each revision caches
    /// separately, so switching versions never clobbers another's files.
    public convenience init(directory: String? = nil, variant: ModelVariant = .default,
                            revision: String? = nil,
                            computeUnits: ComputeUnits = .all,
                            concurrency: Int = Clear.defaultConcurrency) {
        self.init(directory: directory, cacheRoot: nil, variant: variant,
                  revision: .exact(revision ?? ClearModel.revision),
                  computeUnits: computeUnits, concurrency: concurrency)
    }

    /// Like `init(revision: String)`, but with a ``RevisionRequirement``:
    /// `.exact("v0.2.0")` behaves as above, while
    /// `.from("v0.2.0")` (SwiftPM semantics: up to the next major) resolves to
    /// the newest published tag
    /// with the same major version at load time - and, offline, to the newest
    /// already-downloaded revision in range, so an installed device keeps
    /// working without the network. The resolved revision is reported on each
    /// ``Result/modelRevision``.
    public convenience init(directory: String? = nil, variant: ModelVariant = .default,
                            revision: RevisionRequirement,
                            computeUnits: ComputeUnits = .all,
                            concurrency: Int = Clear.defaultConcurrency) {
        self.init(directory: directory, cacheRoot: nil, variant: variant, revision: revision,
                  computeUnits: computeUnits, concurrency: concurrency)
    }

    /// Binding entry point that also supplies the platform base cache root under
    /// which the managed layout lives (the app cache dir on Android, node
    /// `~/.cache` on the web). On Apple/Linux FileManager provides it, so the
    /// public `init(directory:...)` passes `nil`.
    @_spi(ClearBindings)
    public init(directory: String?, cacheRoot: String?,
                variant: ModelVariant = .default,
                revision requirement: RevisionRequirement = .exact(ClearModel.revision),
                computeUnits: ComputeUnits = .all,
                concurrency: Int = Clear.defaultConcurrency) {
        // A variant is its own slice of the model repo, so the loader resolves
        // that distribution rather than the catalog entry's default one; the
        // requirement decides the revision (for ranges, at load time).
        self.variant = variant
        self.revisionRequirement = requirement
        let base = variant.distribution(revision: ClearModel.revision)
        model = LoadedModel(
            resolve: { await base.resolving(requirement, cacheRoot: cacheRoot) },
            isAvailable: {
                // Offline answer: an exact revision checks itself (including a
                // user-populated directory); a range is available when any
                // downloaded revision satisfies it.
                let revisions = requirement.exactRevision.map { [$0] }
                    ?? base.downloadedRevisions(satisfying: requirement, cacheRoot: cacheRoot)
                return revisions.contains {
                    variant.distribution(revision: $0)
                        .isAvailable(cacheDirectory: directory, cacheRoot: cacheRoot)
                }
            },
            directory: directory, cacheRoot: cacheRoot) { files, distribution in
            try await .clear(files: files, variant: variant, revision: distribution.revision,
                             computeUnits: computeUnits, concurrency: concurrency)
        }
    }

    /// Creates an enhancer from explicitly provided assets (the Android/JNI and
    /// custom-deployment paths).
    @_spi(ClearBindings)
    public init(assets: ModelAssets) {
        variant = nil
        revisionRequirement = nil
        model = LoadedModel { assets }
    }

    /// Load a local model file directly (a `.mlmodelc` on Apple, a `.tflite`
    /// elsewhere), skipping the store entirely. For tests and custom
    /// deployments; apps point `directory` at their files instead.
    public init(modelPath: String, computeUnits: ComputeUnits = .all,
                concurrency: Int = Clear.defaultConcurrency) throws {
        // Built eagerly (this initializer throws), then handed to the loader so
        // the rest of the class has one path to its assets.
        let assets = try ModelAssets(modelPath: modelPath, computeUnits: computeUnits, concurrency: concurrency)
        variant = ModelVariant.inferred(fromPath: modelPath)
        revisionRequirement = nil
        model = LoadedModel { assets }
    }

    /// Paths of every downloaded version of the clear model in the managed
    /// cache, one per revision, sorted. The last path component of each entry
    /// is the revision (`.../desert-ant-models/desert-ant-labs/clear/v0.2.0`),
    /// so `models().map { ($0 as NSString).lastPathComponent }` lists the
    /// versions available offline. Only completed downloads appear; a folder
    /// you populated yourself (an explicit `directory`) is not part of the
    /// managed cache and is not listed.
    ///
    /// Note: a revision directory may hold one or both variants' files - the
    /// per-variant check is ``isDownloaded(variant:revision:directory:cacheRoot:)``.
    public static func models(cacheRoot: String? = nil) -> [String] {
        ModelVariant.default.distribution.installedModels(cacheRoot: cacheRoot)
    }

    /// Whether a given variant/revision is already downloaded and intact
    /// (usable offline), without constructing an enhancer. `revision` defaults
    /// to the SDK's pinned ``Clear/modelRevision``; `directory` mirrors the
    /// initializer's parameter (nil = the managed cache).
    public static func isDownloaded(variant: ModelVariant = .default,
                                    revision: String? = nil,
                                    directory: String? = nil,
                                    cacheRoot: String? = nil) -> Bool {
        variant.distribution(revision: revision ?? ClearModel.revision)
            .isAvailable(cacheDirectory: directory, cacheRoot: cacheRoot)
    }

    /// Whether the model is available for this enhancer with no network:
    /// cached (for the managed location) or already present in `directory`.
    public func isDownloaded() -> Bool { model.isDownloaded() }

    /// Await model readiness. The bindings use this to surface load errors
    /// eagerly; apps can just call `enhance`.
    @_spi(ClearBindings)
    public func waitUntilLoaded() async throws {
        _ = try await model.value()
    }

    /// Download the model if needed, reporting download progress 0...1.
    public func download(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await model.download(progress: progress)
    }

    /// Download (if needed) and fully load the model, reporting phase-aware
    /// progress: ``ModelLoadPhase/downloading`` with a bytes-based fraction,
    /// then ``ModelLoadPhase/preparing`` while the inference session is built
    /// (on Apple, the first launch's Core ML compile lands here). Returns once
    /// the model is ready, so the first `enhance` starts instantly. Concurrent
    /// callers join the same load.
    public func load(progress: @escaping @Sendable (ModelLoadProgress) -> Void = { _ in }) async throws {
        try await model.load(progress: progress)
    }

    /// Enhance mono/stereo `samples` at `sampleRate`, returning 48 kHz mono.
    ///
    /// `progress` reports ``Phase/loadingModel`` (only when the model is not
    /// loaded yet), then ``Phase/enhancing``, then ``Phase/mastering``.
    public func enhance(samples: [Float], sampleRate: Double,
                        options: Options = .default,
                        progress: ProgressHandler? = nil) async throws -> Result {
        // Load with progress, so the first call reports the download/compile
        // instead of appearing to hang. `download` is a no-op once loaded, and
        // concurrent callers join the same load.
        if let progress {
            progress(Progress(phase: .loadingModel, fraction: 0))
            try await model.download { progress(Progress(phase: .loadingModel, fraction: $0)) }
        }
        let assets = try await model.value()
        let start = ContinuousClock.now
        progress?(Progress(phase: .analyzing, fraction: 0))
        let input = sampleRate == ClearDSP.sampleRate
            ? samples
            : Resample.linear(samples, from: sampleRate, to: ClearDSP.sampleRate)
        let enhancer = ClearEnhancer(sessions: assets.sessions)
        // The front end (STFT + features) finishes `analyzing`; the chunk loop
        // that follows is `enhancing`. The flip is announced when the front end
        // reports done, so the phase change is not deferred to the first chunk
        // (which on a long file is seconds later).
        var out = try await enhancer.enhance(
            input,
            onAnalysis: { fraction in
                progress?(Progress(phase: .analyzing, fraction: fraction))
                if fraction >= 1 { progress?(Progress(phase: .enhancing, fraction: 0)) }
            },
            onChunk: { progress?(Progress(phase: .enhancing, fraction: $0)) })

        // Strength blend against the (resampled) input.
        let s = Float(options.strength.value)
        if s < 1 {
            let n = min(out.count, input.count)
            for i in 0..<n { out[i] = s * out[i] + (1 - s) * input[i] }
        }

        // Mastering: integrated-LUFS normalization with the preset's gain cap
        // and peak ceiling. `loudnessRangeLU` is not applied (no range stage
        // yet); see `Mastering`.
        var measured: Double? = nil
        var truePeak: Double? = nil
        let mastering = options.mastering
        if mastering.enabled {
            // In place: a returned master would sit alongside `out`, and both
            // are full length.
            measured = Loudness.normalizeInPlace(
                &out, sampleRate: ClearDSP.sampleRate, targetLUFS: mastering.integratedLUFS,
                maxGainDB: mastering.maxLoudnessGainDB, peakCeilingDBFS: mastering.truePeakDBTP)
            truePeak = Limiter.truePeakDBFS([out])
        }
        // Mastering is the tail of `enhancing`, so the phase ends at 1 only
        // once the audio is actually final.
        progress?(Progress(phase: .enhancing, fraction: 1))
        return Result(samples: out, sampleRate: ClearDSP.sampleRate,
                      durationSec: Double(out.count) / ClearDSP.sampleRate,
                      processingSec: elapsedSeconds(since: start), measuredLUFS: measured,
                      measuredTruePeakDBFS: truePeak,
                      modelVariant: assets.variant, modelRevision: assets.revision)
    }

    func elapsedSeconds(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    #if canImport(Foundation) && !os(Android) && !os(WASI)
    /// Decode any audio file, enhance it, and (optionally) write the result at
    /// 48 kHz mono. The output encoding follows `outputPath`'s extension:
    /// `.wav` gives 16-bit PCM, `.m4a`/`.mp4`/`.aac` gives AAC, `.caf`/`.aiff`
    /// gives PCM. An unrecognized extension writes WAV.
    ///
    /// AAC and CAF/AIFF need AVFoundation, so off Apple platforms anything but
    /// `.wav` throws rather than writing WAV bytes under a misleading name.
    /// Filesystem platforms (Apple/Linux); on Android/web use `enhance(bytes:)`.
    @discardableResult
    public func enhance(path: String, to outputPath: String? = nil,
                        options: Options = .default,
                        progress: ProgressHandler? = nil) async throws -> Result {
        #if canImport(AVFoundation)
        // Bounded-memory path: peak stays flat instead of growing with the
        // file. Only when writing a file - a caller that wants the samples back
        // is asking for the whole signal by definition. `Result.samples` is
        // empty here; `durationSec` carries the length.
        if let outputPath {
            return try await enhanceStreaming(path: path, to: outputPath,
                                              options: options, progress: progress)
        }
        #endif
        let samples = try await AudioIO.decode(path: path, sampleRate: ClearDSP.sampleRate)
        let result = try await enhance(samples: samples, sampleRate: ClearDSP.sampleRate,
                                       options: options, progress: progress)
        if let outputPath {
            try AudioIO.write(result.samples, sampleRate: Int(ClearDSP.sampleRate), to: outputPath)
        }
        return result
    }
    #endif

    /// Enhance in-memory audio-file `bytes`, returning enhanced 48 kHz mono
    /// samples and a ready-to-write WAV byte buffer.
    public func enhance(bytes: [UInt8], options: Options = .default,
                        progress: ProgressHandler? = nil) async throws
        -> (result: Result, wav: [UInt8]) {
        let samples = try await AudioIO.decode(bytes: bytes, sampleRate: ClearDSP.sampleRate)
        let result = try await enhance(samples: samples, sampleRate: ClearDSP.sampleRate,
                                       options: options, progress: progress)
        let wav = AudioIO.encodeWAV(result.samples, sampleRate: Int(ClearDSP.sampleRate))
        return (result, wav)
    }
}

/// Errors thrown while loading or running the model. (`MessageError` is
/// `LocalizedError` wherever Foundation exists, so `localizedDescription`
/// shows `message`.)
public enum ClearError: MessageError, Sendable {
    /// On-device enhancement failed or returned an unexpected output.
    case inferenceFailed(String)
    /// A model resource could not be found.
    case modelMissing(String)

    public var message: String {
        switch self {
        case .inferenceFailed(let detail): "On-device speech enhancement failed: \(detail)."
        case .modelMissing(let name): "A Clear model resource was not found: \(name)."
        }
    }
}

#if os(WASI)
public extension Clear {
    /// Build from a JS host inference session (the wasm entry point). The host
    /// (a LiteRT.js session, supplied to the module at instantiation) must have
    /// compiled the model first.
    @_spi(ClearBindings)
    convenience init() throws {
        self.init(assets: ModelAssets(session: try inferenceSession(sdk: ClearModel.sdkInfo)))
    }
}
#endif
