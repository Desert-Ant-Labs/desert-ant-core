import Foundation
import DesertAnt

/// On-device speech enhancement: denoise, dereverb, and loudness-normalize a
/// noisy recording to a podcast-ready 48 kHz mono file. DeepFilterNet3 under the
/// hood, running on Core ML (Apple), ONNX Runtime (Android/Linux), or the JS
/// host (web) through desert-ant-core, with the DSP shared across all platforms.
///
/// ```swift
/// let clear = try Clear(modelPath: "clear-studio.onnx")   // or download via Clear()
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
        /// Integrated loudness target in LUFS (nil disables mastering).
        public var targetLUFS: Double?
        /// True-peak ceiling in dBFS for the master.
        public var peakCeilingDBFS: Double
        /// Cap on the upward loudness gain in dB.
        public var maxGainDB: Double
        public init(strength: Strength = .full, targetLUFS: Double? = -19,
                    peakCeilingDBFS: Double = -1.0, maxGainDB: Double = 12) {
            self.strength = strength
            self.targetLUFS = targetLUFS
            self.peakCeilingDBFS = peakCeilingDBFS
            self.maxGainDB = maxGainDB
        }
        public static let `default` = Options()
    }

    public struct Result: Sendable {
        public let samples: [Float]         // enhanced, 48 kHz mono
        public let sampleRate: Double
        public let durationSec: Double
        public let processingSec: Double
        public let measuredLUFS: Double?
        public var realtimeFactor: Double { processingSec > 0 ? durationSec / processingSec : 0 }
    }

    // Resolving, downloading, single-flighting, and offline availability are
    // `LoadedModel`; Clear adds only how a resolved directory becomes its
    // session pool.
    private let model: LoadedModel<ModelAssets>

    /// Default model sessions to run chunks in parallel over. Native LiteRT is
    /// single-threaded per run, so a pool uses multiple cores; Apple (fast) and
    /// wasm (LiteRT.js is already multi-threaded) use one.
    public static var defaultConcurrency: Int {
        #if canImport(CoreML) || os(WASI)
        return 1                                          // Apple: fast single session; wasm: LiteRT.js already threaded
        #elseif os(Android)
        return max(1, min(ProcessInfo.processInfo.activeProcessorCount, 2))   // cap memory on mobile (~2x model size)
        #else
        return max(1, min(ProcessInfo.processInfo.activeProcessorCount, 4))   // Linux/Windows desktop/server
        #endif
    }

    /// `computeUnits` selects the Core ML compute units on Apple (ignored by the
    /// LiteRT/JS backends). Default `.cpuOnly`: the palettized model benchmarks
    /// ~2x faster on the CPU than the Neural Engine or GPU on M-series Macs.
    /// `concurrency` is the model-session pool size (see `defaultConcurrency`).
    ///
    /// Nothing is bundled with this package. To ship the model with your app,
    /// point `directory` at a folder you populated with the model files: it is
    /// used as-is, offline, and nothing is downloaded.
    public convenience init(directory: String? = nil, computeUnits: ComputeUnits = .cpuOnly,
                            concurrency: Int = Clear.defaultConcurrency) {
        self.init(directory: directory, cacheRoot: nil, computeUnits: computeUnits, concurrency: concurrency)
    }

    /// Binding entry point that also supplies the platform base cache root under
    /// which the managed layout lives (the app cache dir on Android, node
    /// `~/.cache` on the web). On Apple/Linux FileManager provides it, so the
    /// public `init(directory:...)` passes `nil`.
    @_spi(ClearBindings)
    public init(directory: String?, cacheRoot: String?,
                computeUnits: ComputeUnits = .cpuOnly,
                concurrency: Int = Clear.defaultConcurrency) {
        model = LoadedModel(ClearModel.self, directory: directory, cacheRoot: cacheRoot) { files in
            try await .clear(files: files, computeUnits: computeUnits, concurrency: concurrency)
        }
    }

    /// Creates an enhancer from explicitly provided assets (the Android/JNI and
    /// custom-deployment paths).
    @_spi(ClearBindings)
    public init(assets: ModelAssets) {
        model = LoadedModel { assets }
    }

    /// Load a local model file directly (a `.mlmodelc` on Apple, a `.tflite`
    /// elsewhere), skipping the store entirely. For tests and custom
    /// deployments; apps point `directory` at their files instead.
    public init(modelPath: String, computeUnits: ComputeUnits = .cpuOnly,
                concurrency: Int = Clear.defaultConcurrency) throws {
        let sessions = try (0..<max(1, concurrency)).map { _ in
            try inferenceSession(modelPath: modelPath, computeUnits: computeUnits, sdk: ClearModel.sdkInfo)
        }
        model = LoadedModel { ModelAssets(sessions: sessions) }
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

    /// Download the model if needed, reporting progress 0...1.
    public func download(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await model.download(progress: progress)
    }

    /// Enhance mono/stereo `samples` at `sampleRate`, returning 48 kHz mono.
    public func enhance(samples: [Float], sampleRate: Double,
                        options: Options = .default) async throws -> Result {
        let assets = try await model.value()
        let start = Date()
        let input = sampleRate == ClearDSP.sampleRate
            ? samples
            : Resample.linear(samples, from: sampleRate, to: ClearDSP.sampleRate)
        let enhancer = ClearEnhancer(sessions: assets.sessions)
        var out = try await enhancer.enhance(input)

        // Strength blend against the (resampled) input.
        let s = Float(options.strength.value)
        if s < 1 {
            let n = min(out.count, input.count)
            for i in 0..<n { out[i] = s * out[i] + (1 - s) * input[i] }
        }

        var measured: Double? = nil
        if let target = options.targetLUFS {
            let (mastered, lufs) = Loudness.normalize(
                out, sampleRate: ClearDSP.sampleRate, targetLUFS: target,
                maxGainDB: options.maxGainDB, peakCeilingDBFS: options.peakCeilingDBFS)
            out = mastered
            measured = lufs
        }
        return Result(samples: out, sampleRate: ClearDSP.sampleRate,
                      durationSec: Double(out.count) / ClearDSP.sampleRate,
                      processingSec: Date().timeIntervalSince(start), measuredLUFS: measured)
    }

    #if canImport(Foundation) && !os(Android) && !os(WASI)
    /// Decode any audio file, enhance it, and (optionally) write a 48 kHz WAV.
    /// Filesystem platforms (Apple/Linux); on Android/web use `enhance(bytes:)`.
    @discardableResult
    public func enhance(path: String, to outputPath: String? = nil,
                        options: Options = .default) async throws -> Result {
        let samples = try await AudioIO.decode(path: path, sampleRate: ClearDSP.sampleRate)
        let result = try await enhance(samples: samples, sampleRate: ClearDSP.sampleRate, options: options)
        if let outputPath {
            try AudioIO.writeWAV(result.samples, sampleRate: Int(ClearDSP.sampleRate), to: outputPath)
        }
        return result
    }
    #endif

    /// Enhance in-memory audio-file `bytes`, returning enhanced 48 kHz mono
    /// samples and a ready-to-write WAV byte buffer.
    public func enhance(bytes: [UInt8], options: Options = .default) async throws
        -> (result: Result, wav: [UInt8]) {
        let samples = try await AudioIO.decode(bytes: bytes, sampleRate: ClearDSP.sampleRate)
        let result = try await enhance(samples: samples, sampleRate: ClearDSP.sampleRate, options: options)
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
    /// (`__ClearHost`, a LiteRT.js session) must be installed first.
    @_spi(ClearBindings)
    convenience init(hostGlobal: String = ClearModel.hostGlobal) throws {
        self.init(assets: ModelAssets(session: try inferenceSession(hostGlobal: hostGlobal, sdk: ClearModel.sdkInfo)))
    }
}
#endif
