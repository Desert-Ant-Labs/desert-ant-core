#if os(WASI)
import Foundation
import JavaScriptKit
@_spi(VozWeb) import Voz

// The `@JS` surface: load once, then transcribe a Float32Array. Everything else
// a browser needs (fetching the bundle, compiling the models, choosing an
// execution provider) is the JS host's business and it is better at it.
//
// Its own file rather than `main.swift`, because BridgeJS does not scan the
// executable's main file and an `@JS` declaration there generates nothing:
// `Exports` comes out empty and the package sees no entry points.


/// What this module's model is, for the JS package that wraps it.
///
/// `files` is what a `modelBaseUrl` has to serve, and `revision` which Hub
/// revision the default URL points at. Reported from `Catalog.swift` rather
/// than restated in the package's `codec.js`, because a mirrored list with
/// nothing checking it is a renamed artifact that breaks the self-hosted path
/// silently.
@JS public struct VozModelInfo {
    public var id: String
    public var sdkVersion: String
    public var repo: String
    public var revision: String
    public var files: [String]

    public init(id: String, sdkVersion: String, repo: String, revision: String, files: [String]) {
        self.id = id
        self.sdkVersion = sdkVersion
        self.repo = repo
        self.revision = revision
        self.files = files
    }
}

@JS public func modelInfo() -> VozModelInfo {
    VozModelInfo(id: VozModel.id, sdkVersion: VozModel.sdkVersion, repo: VozModel.repo,
                 revision: VozModel.webRevision,
                 files: VozModel.files[.web] ?? [])
}

/// A word and when it sounds, in seconds from the start of the audio.
///
/// The whole reason this surface is not a byte payload. Times land on encoder
/// frame boundaries (80 ms), which is what the Swift API documents too.
@JS public struct VozWord {
    public var text: String
    public var start: Double
    public var end: Double

    // Explicit and public for the same reason `ModelInfo`'s is: the generated
    // bridge builds this from a `@_transparent` function, which cannot see an
    // internal memberwise init.
    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A transcript: the text, the words with their times, and what it cost.
@JS public struct VozTranscript {
    public var text: String
    public var words: [VozWord]
    /// Seconds of audio.
    public var duration: Double
    /// Seconds of wall clock spent transcribing it.
    public var processingTime: Double

    public init(text: String, words: [VozWord], duration: Double, processingTime: Double) {
        self.text = text
        self.words = words
        self.duration = duration
        self.processingTime = processingTime
    }
}

/// The loaded recogniser, kept alive between calls.
///
/// `nonisolated(unsafe)` as `WasmBindings`' installed host is, and for the same
/// reason: wasm here is one thread, so the only concurrency is the interleaving
/// of awaits on it. `Voz` itself is an actor and queues concurrent
/// transcriptions; this reference is only ever written by `load`.
nonisolated(unsafe) private var voz: Voz?

/// Build the recogniser from sidecars the host already fetched.
///
/// `lanes`, `batch` and `fused` come out of the bundle's own `meta.json`: they
/// describe the graphs the host compiled, so they are the host's to report
/// rather than this module's to assume.
@JS public func load(
    meta: JSUint8Array, vocab: JSUint8Array, embedding: JSUint8Array,
    lanes: Int, batch: Int, fused: Bool
) async throws(JSException) -> Bool {
    func bytes(_ array: JSUint8Array) -> Data {
        array.withUnsafeBytes { Data($0) }
    }
    do {
        voz = try await Voz.web(meta: bytes(meta), vocab: bytes(vocab),
                                embedding: bytes(embedding), lanes: lanes,
                                batch: batch, fused: fused)
        return true
    } catch {
        throw JSException(message: "\(error)")
    }
}

/// Whether ``load(meta:vocab:embedding:lanes:batch:fused:)`` has run.
@JS public func isLoaded() -> Bool { voz != nil }

/// Transcribe audio the host decodes in pieces, so memory does not grow with
/// the recording.
///
/// `pull(count)` returns a promise of up to `count` more mono 16 kHz samples as
/// a `Float32Array`, or of an empty one when the audio is finished. A promise
/// because reading a slice of a file is asynchronous everywhere it matters: the
/// point of this entry point is that the host has NOT read the file yet.
///
/// It is called when the pipeline needs audio, and the pipeline frees what is
/// behind the window it is working on, so what stays resident is a window and a
/// chunk rather than the recording.
///
/// The whole-array entry point below still exists, because samples a caller
/// already has in hand should not have to be handed back a slice at a time.
@JS public func transcribeStream(
    seconds: Double, totalSamples: Int,
    pull: @escaping (Int) -> JSObject?,
    onProgress: @escaping (Double) -> Void
) async throws(JSException) -> VozTranscript {
    guard let voz else {
        throw JSException(message: "voz: load() first")
    }
    // Both closures are JS functions, which are not Sendable, and both are
    // called on this one wasm thread. Same reasoning as `Crossing` in
    // `Engine+Wasm.swift`.
    struct Source: @unchecked Sendable {
        let pull: (Int) -> JSObject?
        let report: (Double) -> Void
    }
    let source = Source(pull: pull, report: onProgress)
    do {
        let result = try await voz.transcribe(
            duration: seconds,
            totalSamples: totalSamples > 0 ? totalSamples : nil,
            pull: { count in
                guard let pending = source.pull(count),
                      let promise = JSPromise(from: pending.jsValue) else { return [] }
                let settled = try await awaited(promise)
                guard let chunk = JSFloat32Array(from: settled) else { return [] }
                return chunk.withUnsafeBytes { Array($0) }
            },
            progress: { progress in source.report(progress.fractionCompleted) })
        return VozTranscript(
            text: result.text,
            words: result.words.map { VozWord(text: $0.text, start: $0.start, end: $0.end) },
            duration: result.duration,
            processingTime: result.processingTime)
    } catch {
        throw JSException(message: "\(error)")
    }
}

/// A JS promise's value, awaited without sending a non-Sendable across an
/// isolation domain. Same shape and same reasoning as `settle` in
/// `Engine+Wasm.swift`: one wasm thread, so nothing crosses.
private func awaited(_ promise: JSPromise) async throws -> JSValue {
    struct Crossing: @unchecked Sendable { let value: JSValue }
    struct Failure: Error { let message: String }
    let crossing: Crossing = try await withCheckedThrowingContinuation { continuation in
        _ = promise.then(
            success: { value in
                continuation.resume(returning: Crossing(value: value))
                return .undefined
            },
            failure: { error in
                continuation.resume(throwing: Failure(message: "\(error)"))
                return .undefined
            })
    }
    return crossing.value
}

/// Transcribe mono 16 kHz samples.
///
/// `onProgress` receives the fraction in [0, 1]. Not optional because BridgeJS
/// rejects an optional closure parameter; the JS seam passes a no-op when the
/// caller supplied none.
@JS public func transcribe(
    samples: JSFloat32Array, onProgress: @escaping (Double) -> Void
) async throws(JSException) -> VozTranscript {
    guard let voz else {
        throw JSException(message: "voz: load() first")
    }
    let audio = samples.withUnsafeBytes { Array($0) }
    // `Voz.transcribe` takes a `@Sendable` progress callback, and a JS closure
    // is not Sendable. Safe here for the reason `Crossing` in
    // `Engine+Wasm.swift` is: this wasm is one thread, and the callback is
    // invoked on it, so there is no domain for it to cross.
    struct Reporter: @unchecked Sendable {
        let report: (Double) -> Void
    }
    let reporter = Reporter(report: onProgress)
    do {
        let result = try await voz.transcribe(samples: audio) { progress in
            reporter.report(progress.fractionCompleted)
        }
        return VozTranscript(
            text: result.text,
            words: result.words.map { VozWord(text: $0.text, start: $0.start, end: $0.end) },
            duration: result.duration,
            processingTime: result.processingTime)
    } catch {
        throw JSException(message: "\(error)")
    }
}
#endif
