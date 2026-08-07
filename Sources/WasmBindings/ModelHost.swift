// Everything behind the exported entry points in `Exports.swift`: one
// model-agnostic engine, so a model's `Web/main.swift` is one `installWasmModel`
// call. `deviceId` is already resolved to a string by the JS seam before the
// call, so a getter can never be read from the wrong task tree here.
#if os(WASI)
import DesertAnt
import JavaScriptEventLoop
import JavaScriptKit

/// One model a wasm module exposes: the binding that constructs it, plus the
/// only genuinely model-specific piece of the wasm path - how files the JS host
/// fetched itself (the `modelBaseUrl` option, the browser's equivalent of
/// pointing a native SDK at a directory that already holds the model) become an
/// instance. Everything else is derived from the model's declaration.
public struct WasmModel {
    let id: String
    let sdk: SDKInfo
    /// The catalog facts the JS SDK reads back through `modelInfo()`, so a model
    /// package restates none of them.
    let declaration: Declaration
    let binding: any ModelBinding.Type
    let selfHosted: ([String: [UInt8]], any InferenceSession) throws -> any BoundModel

    /// - Parameters:
    ///   - declaration: the model's catalog entry; supplies the id and the usage
    ///     identity every session is tracked under.
    ///   - binding: the model's `ModelBinding`, as used by the C ABI.
    ///   - selfHosted: build the model from the sidecar files the host fetched
    ///     (keyed by their catalog file names) and a session backed by the host's
    ///     already-compiled model.
    public init<Model: ModelDeclaration>(
        _ declaration: Model.Type,
        binding: any ModelBinding.Type,
        selfHosted: @escaping ([String: [UInt8]], any InferenceSession) throws -> any BoundModel
    ) {
        self.id = Model.id
        self.sdk = Model.sdkInfo
        self.declaration = Declaration(
            id: Model.id, sdkVersion: Model.sdkVersion,
            artifact: Model.artifact,
            sidecars: Model.files[.web]?.filter { $0 != Model.artifact } ?? [])
        self.binding = binding
        self.selfHosted = selfHosted
    }
}

/// The catalog facts a model's JS package needs, flattened out of the generic
/// declaration so `ModelHost` stays non-generic.
struct Declaration {
    let id: String
    let sdkVersion: String
    let artifact: String
    let sidecars: [String]
}

extension ModelHost {
    /// What `modelInfo()` reports.
    var declaration: Declaration { model.declaration }
}

/// Install the model this wasm module exposes. A model's `Web/main.swift` is this
/// call and nothing else: the exported surface is `Exports.swift`, which forwards
/// to the host installed here.
///
/// A wasm module carries exactly one model (one `<Model>Web` product per model),
/// so this is a single global rather than a registry keyed by model id.
public func installWasmModel(_ model: WasmModel) {
    installedModelHost = ModelHost(model)
}

/// Nil is unreachable in a built module: `Web/main.swift` runs at startup, before
/// JS can hold the exports at all. So the entry points that cannot otherwise fail
/// read this directly and fall back to "nothing loaded" rather than growing a
/// throwing signature (and a `catch` in every JS caller) for a state that cannot
/// happen.
nonisolated(unsafe) var installedModelHost: ModelHost?

/// The installed host for the entry points that can genuinely fail, which report
/// the impossible case as the bug it would be rather than inventing a result.
func installedHost() throws(JSException) -> ModelHost {
    guard let host = installedModelHost else {
        throw failure("no model is installed in this WebAssembly module")
    }
    return host
}

/// The engine behind the exported entry points: loaded instances behind the
/// opaque numeric handles JS holds (the wasm counterpart of the C ABI's retained
/// pointers), and the one implementation of each entry point.
///
/// wasm is single-threaded, so this holds its state without a lock. Creating it
/// installs the JS-backed global executor the `async` entry points run on, which
/// is why `installWasmModel` is all a model's entry point does.
public final class ModelHost {
    private let model: WasmModel
    private var models: [Int: any BoundModel] = [:]
    private var nextHandle = 1

    init(_ model: WasmModel) {
        JavaScriptEventLoop.installGlobalExecutor()
        self.model = model
    }

    // MARK: creating

    /// Lazy, like the native constructor: no download and no model load until
    /// `download`/`run`. `cacheRoot` is the base for the managed nested cache
    /// (node `~/.cache`; empty in the browser) and `directory`, when non-empty,
    /// is an explicit model directory (adopt the files there, else download into
    /// it). Empty strings mean "not supplied", so a JS seam can pass `""`.
    func create(cacheRoot: String?, directory: String?) -> Int {
        store(model.binding.make(
            cacheRoot: present(cacheRoot), directory: present(directory)))
    }

    /// The host fetched the sidecars and compiled the model into its own session
    /// already, so only the sidecars cross into wasm (the multi-MB artifact never
    /// does).
    func createSelfHosted(files: [String: JSUint8Array]) throws(JSException) -> Int {
        do {
            let session = try inferenceSession(sdk: model.sdk)
            return store(try model.selfHosted(files.mapValues(bytes), session))
        } catch {
            throw failure("could not build the model from the supplied files: \(error)")
        }
    }

    // MARK: using

    func isDownloaded(handle: Int) -> Bool {
        (try? loaded(handle).isDownloaded()) ?? false
    }

    /// Fetch and verify ahead of time, then load, so the first `run` is instant
    /// and load errors surface here. A no-op once available. `onProgress` gets
    /// the fraction in [0, 1].
    func download(
        handle: Int, onProgress: @escaping (Double) -> Void
    ) async throws(JSException) -> Bool {
        let instance = try loaded(handle)
        // The model's progress closure is `@Sendable` and a JS-backed closure is
        // not: a JS reference belongs to the thread whose JS context created it.
        // This file is `#if os(WASI)` and that runtime is single-threaded, so
        // there is no second thread to reach, but the compiler cannot know that
        // and the capture is an error in the Swift 6 language mode. Say it once
        // here rather than scattering unchecked captures.
        let progress = SingleThreadedJS(onProgress)
        do {
            try await instance.download { fraction in progress.value(fraction) }
        } catch {
            throw failure("the model download failed: \(error)")
        }
        return true
    }

    /// The model decodes `options` and encodes the result, so this stays
    /// model-agnostic.
    func run(
        handle: Int, text: String, options: JSUint8Array?, group: String?, deviceId: String?
    ) async throws(JSException) -> JSUint8Array {
        let instance = try loaded(handle)
        let payload = await InferenceContext.$deviceId.withValue(present(deviceId)) {
            await InferenceContext.withCallGroup(id: present(group)) {
                await instance.run(text: text, options: FFIReader(bytes(options)))
            }
        }
        guard let payload else { throw failure("the model failed to run") }
        return JSUint8Array(payload)
    }

    /// Release a call group opened by passing `group` to `run`.
    func endCallGroup(id: String?) {
        if let id = present(id) { InferenceContext.endCallGroup(id) }
    }

    func destroy(handle: Int) {
        models[handle] = nil
    }

    /// Force any tracked session to emit now (bypassing the debounce + re-emit
    /// window) and await the send, so the usage POST goes out before the caller
    /// continues. Requires `globalThis.__dalHttpDebug`.
    func flushTelemetry() async -> Bool {
        await TelemetryDebug.shared.flushAndWait()
        return true
    }

    // MARK: handles

    private func store(_ model: any BoundModel) -> Int {
        let handle = nextHandle
        nextHandle += 1
        models[handle] = model
        return handle
    }

    /// The instance behind a handle JS passed back.
    private func loaded(_ handle: Int) throws(JSException) -> any BoundModel {
        guard let model = models[handle] else {
            throw failure("unknown model handle \(handle)")
        }
        return model
    }
}

// MARK: JS plumbing

/// Carries a JS-backed value into a `@Sendable` closure on wasm (see
/// `download`).
private struct SingleThreadedJS<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// The one way this ABI reports a failure to JS: a thrown JS error, which
/// becomes a rejected promise for the `async` entry points.
private func failure(_ message: String) -> JSException {
    JSException(message: message)
}

/// Empty strings mean "not supplied" so JS hosts can pass `""` where a value is
/// absent (as the node/browser seams do).
private func present(_ value: String?) -> String? {
    guard let value, !value.isEmpty else { return nil }
    return value
}

private func bytes(_ array: JSUint8Array) -> [UInt8] {
    array.withUnsafeBytes { Array($0) }
}

private func bytes(_ array: JSUint8Array?) -> [UInt8] {
    guard let array else { return [] }
    return bytes(array)
}
#endif
