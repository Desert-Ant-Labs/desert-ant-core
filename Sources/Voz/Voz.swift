#if canImport(CoreML)
import CoreML
#endif
import Foundation
import DesertAnt

public enum VozError: Error, CustomStringConvertible, Sendable {
    case unsupportedPlatform
    case invalidModel(String)
    case invalidAudio(String)

    public var description: String {
        switch self {
        case .unsupportedPlatform:
            return "Voz has no inference backend on this platform"
        case .invalidModel(let m): return "invalid model: \(m)"
        case .invalidAudio(let m): return "invalid audio: \(m)"
        }
    }
}

/// On-device speech recognition: a transcript with word-level timestamps,
/// running entirely on the Neural Engine.
///
/// ```swift
/// let voz = try await Voz()
/// let result = try await voz.transcribe(url) { print($0.fractionCompleted) }
/// print(result.text, result.words.first?.start ?? 0)
/// ```
///
/// The model downloads on first use and is cached; pass a `directory` to adopt
/// files you have already placed somewhere, or call ``download(progress:)`` to
/// fetch it ahead of time.
public actor Voz {

    /// How far along a transcription is, and what it has produced so far.
    public struct Progress: Sendable {
        /// 0...1 over the whole request.
        public let fractionCompleted: Double
    }

    public struct Result: Sendable {
        /// The full transcript.
        public let text: String
        /// Every word with the time it starts. Resolution is 80 ms.
        public let words: [Word]
        /// Length of the audio transcribed.
        public let duration: TimeInterval
        /// Wall-clock time spent transcribing it.
        public let processingTime: TimeInterval
        /// Seconds of audio processed per second of wall clock.
        public var realtimeFactor: Double {
            processingTime > 0 ? duration / processingTime : 0
        }
    }

    private let pipeline: Pipeline
    // Actor isolation is not a lock across awaits, and a transcription suspends
    // at every model call - the browser's are promises, and the native decode
    // join is an await - while the pipeline's buffers are still live. Two
    // concurrent calls interleaved into one set of them.
    private var transcribing = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquirePipeline() async {
        if transcribing {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            transcribing = true
        }
    }

    private func releasePipeline() {
        if waiting.isEmpty {
            transcribing = false
        } else {
            waiting.removeFirst().resume()
        }
    }
    /// One turnstile per instance. See UsageTracking.swift: this model drives
    /// Core ML directly rather than through `Inference`, so it opens its own
    /// rather than inheriting the session factory's.
    // Usage is reported through Core ML's own client, which a browser build does
    // not have: UsageTracking.swift is `#if canImport(CoreML)` whole.
    #if canImport(CoreML)
    private let usage: UsageTurnstile?
    #endif
    /// Audio rate the model expects. Input at another rate is resampled.
    public nonisolated let sampleRate: Double


    /// The languages the model was trained on, as ISO 639-1 codes.
    ///
    /// It does not detect which one it is hearing, and audio in a language that
    /// is not here produces confident nonsense rather than an error. A caller
    /// routing mixed input should name the language first (see `Ear`) and check
    /// it against this set.
    public static let supportedLanguages: Set<String> = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi",
        "fr", "hr", "hu", "it", "lt", "lv", "mt", "nl", "pl",
        "pt", "ro", "ru", "sk", "sl", "sv", "uk",
    ]

    // MARK: - Availability

    /// Whether the model is already on disk, so a caller can decide whether to
    /// show a download step.
    public static func isDownloaded(directory: String? = nil, cacheRoot: String? = nil) -> Bool {
        VozModel.isAvailable(directory: directory, cacheRoot: cacheRoot)
    }

    /// Fetch the model without loading it, for downloading during onboarding.
    ///
    /// Worth doing: the first load after a download pays a one-time Neural Engine
    /// specialization of roughly 20 s, and every load after it takes about
    /// 0.2 s. Doing both here keeps that cost off the first transcription.
    @discardableResult
    public static func download(
        directory: String? = nil,
        cacheRoot: String? = nil,
        progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws -> String {
        try await VozModel.resolve(directory: directory, cacheRoot: cacheRoot,
                                        progress: progress).rootPath
    }

    // MARK: - Creation

    #if canImport(CoreML)
    /// Load the model, downloading it first if needed.
    public init(
        directory: String? = nil,
        cacheRoot: String? = nil,
        progress: @Sendable @escaping (DownloadProgress) -> Void = { _ in }
    ) async throws {
        guard VozModel.supports(.current) else { throw VozError.unsupportedPlatform }
        let stored = try await VozModel.resolve(directory: directory, cacheRoot: cacheRoot,
                                                     progress: progress)
        try self.init(modelDirectory: URL(fileURLWithPath: stored.rootPath))
    }

    /// Load from a directory of model files you manage yourself.
    public init(modelDirectory: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        func read(_ name: String) throws -> Data {
            try Data(contentsOf: modelDirectory.appendingPathComponent(name))
        }
        let assets = try Assets(meta: try read("meta.json"), vocab: try read("vocab.json"),
                                embeddingBytes: try Data(
                                    contentsOf: modelDirectory
                                        .appendingPathComponent("embedding.f16"),
                                    options: .mappedIfSafe))
        // The engine binds these buffers into its feature providers and output
        // backings, so both halves have to be handed the same set.
        let lanes = try CoreMLEngine.declaredLanes(directory: modelDirectory,
                                                   computeUnits: computeUnits)
        // The engine says how many encodes it will overlap, and the buffers
        // carry a slot for each: they are bound into its providers at load.
        // One window per slot, because this graph is a fixed shape.
        let buffers = try PipelineBuffers(configuration: assets.configuration, lanes: lanes,
                                          batch: 1, depth: CoreMLEngine.encodeDepthForLoad)
        let engine = try CoreMLEngine(directory: modelDirectory, computeUnits: computeUnits,
                                      buffers: buffers)
        pipeline = Pipeline(assets: assets, engine: engine, buffers: buffers)
        sampleRate = Double(assets.configuration.sampleRate)
        #if canImport(CoreML)
        usage = makeTurnstile()
        #endif
    }
    #endif

    /// Load from sidecars and an engine the caller built.
    ///
    /// This is the seam the wasm entry point uses: the browser fetched the
    /// files and compiled the models itself, so there is no directory to read.
    init(assets: Assets, engine: Engine, buffers: PipelineBuffers) {
        pipeline = Pipeline(assets: assets, engine: engine, buffers: buffers)
        sampleRate = Double(assets.configuration.sampleRate)
        #if canImport(CoreML)
        usage = makeTurnstile()
        #endif
    }

    // MARK: - Transcription

    /// Transcribe mono samples at ``sampleRate``.
    public func transcribe(
        samples: [Float],
        progress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Result {
        guard !samples.isEmpty else { throw VozError.invalidAudio("no samples") }
        var stream = ArrayAudioStream(samples)
        return try await transcribe(stream: &stream,
                              duration: Double(samples.count) / sampleRate,
                              progress: progress)
    }

    /// Transcribe from a source that is read as it goes, so that a long
    /// recording does not have to be resident all at once.
    func transcribe(
        stream: inout some AudioStream,
        duration: Double,
        progress: @Sendable (Progress) -> Void
    ) async throws -> Result {
        await acquirePipeline()
        defer { releasePipeline() }
        // Every public entry point funnels through here, so this is the one
        // place a transcription is counted. Fire-and-forget: the turnstile
        // must never sit between the caller and their transcript.
        #if canImport(CoreML)
        if let usage { Task { await usage.record() } }
        #endif
        let started = Date()
        let (text, words) = try await pipeline.run(stream: &stream) {
            progress(Progress(fractionCompleted: min(1, max(0, $0))))
        }
        progress(Progress(fractionCompleted: 1))
        guard !words.isEmpty || duration > 0 else {
            throw VozError.invalidAudio("no samples")
        }
        let bounded = words.map {
            $0.end <= duration ? $0
                : Word(text: $0.text, start: Swift.min($0.start, duration), end: duration)
        }
        return Result(text: text, words: bounded, duration: duration,
                      processingTime: Date().timeIntervalSince(started))
    }
}

#if os(WASI)
public extension Voz {
    /// Build a recogniser from sidecars the browser already fetched, running
    /// the models through the JavaScript host on `globalThis.__vozHost`.
    ///
    /// `@_spi` rather than public API: the wasm entry point is the only caller,
    /// and the shape of this depends on how the host compiles its models.
    @_spi(VozWeb)
    static func web(meta: Data, vocab: Data, embedding: Data, lanes: Int,
                    batch: Int, fused: Bool) async throws -> Voz {
        guard lanes > 0, batch > 0 else {
            throw VozError.invalidModel("lane and batch counts must be positive")
        }
        let assets = try Assets(meta: meta, vocab: vocab, embeddingBytes: embedding)
        let buffers = try PipelineBuffers(configuration: assets.configuration, lanes: lanes,
                                          batch: batch)
        let engine = try WasmEngine(configuration: assets.configuration, lanes: lanes,
                                    batch: batch, fused: fused)
        return Voz(assets: assets, engine: engine, buffers: buffers)
    }
}
#endif
