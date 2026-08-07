// The WebAssembly half of the cross-language bindings: one model-agnostic
// export surface, the wasm twin of a model's native entry points.
//
// A model's wasm entry point used to hand-write its own globals (`load`,
// `loadSelfHosted`, a per-model `suggest`/`redaction`, the promise plumbing, the
// device-id collector, the exports object) - about 130 lines that differed only
// in names. The C ABI solved that problem once already: options in and results
// out cross as `FFIBuffer` payloads the model itself encodes, so one surface
// serves every model and the host picks the model by id. This file applies the
// same shape to wasm, so a model's `Web/main.swift` is just its declaration plus
// how the JS host's self-hosted files become an instance.
//
// After `installWasmExports`, the module exposes one entry per installed model:
//
//     globalThis.__DesertAntExports.<modelId> = {
//       create(cacheRoot?, directory?)                 -> handle,
//       createSelfHosted({ name: string | Uint8Array }) -> handle,
//       isDownloaded(handle)                           -> boolean,
//       download(handle, onProgress?)                  -> Promise<boolean>,
//       run(handle, text, options?, group?, deviceId?) -> Promise<Uint8Array>,
//       endCallGroup(id),
//       destroy(handle),
//       flushTelemetry()                               -> Promise<boolean>,
//     }
//
// Keyed by model id rather than a single flat object, so two SDK packages loaded
// on the same page each register their own entry instead of racing to overwrite
// one global. `options` and the resolved `Uint8Array` are the model's own FFI
// payloads (see its `Binding.swift`), which is what lets this file name no
// model. `deviceId` may be a string or a zero-arg function returning one; it is
// collected before the first `await` and bound to that call's task tree, so
// concurrent calls on a multi-tenant host stay isolated. `group` bills several
// runs as one usage call (release it with `endCallGroup`), matching `dal_run`.
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
    let hostGlobal: String
    let sdk: SDKInfo
    let binding: any ModelBinding.Type
    let selfHosted: ([String: [UInt8]], any InferenceSession) throws -> any BoundModel

    /// - Parameters:
    ///   - declaration: the model's catalog entry; supplies the id, the JS host
    ///     global, and the usage identity every session is tracked under.
    ///   - binding: the model's `ModelBinding`, as used by the C ABI.
    ///   - selfHosted: build the model from the sidecar files the host fetched
    ///     (keyed by their catalog file names) and a session backed by the host's
    ///     already-compiled model.
    public init<Declaration: ModelDeclaration>(
        _ declaration: Declaration.Type,
        binding: any ModelBinding.Type,
        selfHosted: @escaping ([String: [UInt8]], any InferenceSession) throws -> any BoundModel
    ) {
        self.id = Declaration.id
        self.hostGlobal = Declaration.hostGlobal
        self.sdk = Declaration.sdkInfo
        self.binding = binding
        self.selfHosted = selfHosted
    }
}

/// Errors this ABI reports to JS as a rejected promise.
enum WasmABIError: Error, CustomStringConvertible {
    case unknownHandle(Int)
    case runFailed
    case selfHostedFailed

    var description: String {
        switch self {
        case let .unknownHandle(h): "unknown model handle \(h)"
        case .runFailed: "the model failed to run"
        case .selfHostedFailed: "could not build the model from the supplied files"
        }
    }
}

// Loaded instances behind the opaque numeric handles JS holds, the wasm
// counterpart of the C ABI's retained pointers. wasm is single-threaded, so
// plain globals need no lock. The closures are retained here too: they outlive
// `installWasmExports`, and their lifetime is the module's.
private nonisolated(unsafe) var models: [Int: any BoundModel] = [:]
private nonisolated(unsafe) var nextHandle = 1
private nonisolated(unsafe) var retained: [JSClosure] = []

/// Carries a JS value into a `@Sendable` closure on wasm.
///
/// `JSObject` is deliberately not `Sendable`: a JS reference belongs to the
/// thread whose JS context created it. This module is `#if os(WASI)` and that
/// runtime is single-threaded, so there is no second thread to reach - but the
/// compiler cannot know that, and the capture is an error in the Swift 6
/// language mode rather than a warning. This states the reasoning in one place
/// instead of scattering unchecked captures.
private struct SingleThreadedJS<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

private func store(_ model: any BoundModel) -> Int {
    let handle = nextHandle
    nextHandle += 1
    models[handle] = model
    return handle
}

/// The instance behind a handle JS passed back.
private func loaded(_ handle: Int) throws -> any BoundModel {
    guard let model = models[handle] else { throw WasmABIError.unknownHandle(handle) }
    return model
}

/// Install the shared ABI for `models` on `globalThis.__DesertAntExports`, and
/// start the JS-backed global executor the async entry points run on. Call this
/// once from a model's wasm entry point.
public func installWasmExports(_ wasmModels: [WasmModel]) {
    JavaScriptEventLoop.installGlobalExecutor()
    let registry = JSObject.global.__DesertAntExports.object ?? JSObject.global.Object.function!.new()
    for model in wasmModels { registry[model.id] = .object(exports(for: model)) }
    JSObject.global.__DesertAntExports = .object(registry)
}

private func exports(for model: WasmModel) -> JSObject {
    let exports = JSObject.global.Object.function!.new()

    // create(cacheRoot?, directory?): lazy, like the native constructor - no download and
    // no model load until `download`/`run`. `cacheRoot` is the base for the
    // managed nested cache (node `~/.cache`; empty in the browser) and
    // `directory`, when non-empty, is an explicit model directory (adopt the
    // files there, else download into it).
    exports.create = closure { args in
        .number(Double(store(model.binding.make(
            cacheRoot: text(args, 0), directory: text(args, 1)))))
    }

    // createSelfHosted(files): the host fetched the sidecars and compiled the
    // model into its own session already, so only the sidecars cross into wasm
    // (the multi-MB artifact never does). 0 if the files are not what the model
    // needs.
    exports.createSelfHosted = closure { args in
        do {
            let session = try inferenceSession(hostGlobal: model.hostGlobal, sdk: model.sdk)
            return .number(Double(store(try model.selfHosted(sidecars(args.first), session))))
        } catch {
            return .number(0)
        }
    }

    exports.isDownloaded = closure { args in
        .boolean((try? loaded(handle(args, 0)).isDownloaded()) ?? false)
    }

    // download(handle, onProgress?): fetch and verify ahead of time, then load,
    // so the first `run` is instant and load errors surface here. A no-op once
    // available. `onProgress`, when a function, gets the fraction in [0, 1].
    exports.download = promise { args in
        // `download`'s progress closure is @Sendable and JSObject is not
        // Sendable, which is a warning today and an error in the Swift 6
        // language mode. wasm here is single-threaded, so there is no other
        // thread for the callback to reach; say that explicitly rather than
        // leaning on a diagnostic that is about to become fatal.
        let onProgress = SingleThreadedJS(args.count > 1 ? args[1].function : nil)
        try await loaded(handle(args, 0)).download { fraction in
            if let callback = onProgress.value { _ = callback(fraction) }
        }
        return .boolean(true)
    }

    // run(handle, text, options?, group?, deviceId?): the model decodes
    // `options` and encodes the result, so this ABI stays model-agnostic.
    exports.run = promise { args in
        let input = args.count > 1 ? (args[1].string ?? "") : ""
        let options = bytes(args.count > 2 ? args[2] : nil) ?? []
        let group = text(args, 3)
        let deviceId = collectDeviceId(args.count > 4 ? args[4] : nil)
        let instance = try loaded(handle(args, 0))
        let payload = await InferenceContext.$deviceId.withValue(deviceId) {
            await InferenceContext.withCallGroup(id: group) {
                await instance.run(text: input, options: FFIReader(options))
            }
        }
        guard let payload else { throw WasmABIError.runFailed }
        return JSTypedArray<UInt8>(payload).jsValue
    }

    /// Release a call group opened by passing `group` to `run`.
    exports.endCallGroup = closure { args in
        if let id = text(args, 0) { InferenceContext.endCallGroup(id) }
        return .undefined
    }

    exports.destroy = closure { args in
        models[handle(args, 0)] = nil
        return .undefined
    }

    // flushTelemetry(): force any tracked session to emit now (bypassing the
    // debounce + re-emit window) and await the send, so the usage POST goes out
    // before the caller continues. Requires `globalThis.__dalHttpDebug`.
    exports.flushTelemetry = promise { _ in
        await TelemetryDebug.shared.flushAndWait()
        return .boolean(true)
    }

    return exports
}

// MARK: JS plumbing

/// A retained synchronous JS function.
private func closure(_ body: @escaping ([JSValue]) -> JSValue) -> JSValue {
    let fn = JSClosure { args in body(args) }
    retained.append(fn)
    return .object(fn)
}

/// A retained JS function returning a promise, with `throw` rejecting it. Every
/// async entry point here is the same shape, so the error handling lives once.
private func promise(_ body: @escaping ([JSValue]) async throws -> JSValue) -> JSValue {
    closure { args in
        JSPromise { resolve in
            Task {
                do {
                    resolve(.success(try await body(args)))
                } catch {
                    resolve(.failure(.string(String(describing: error))))
                }
            }
        }.jsValue
    }
}

private func handle(_ args: [JSValue], _ index: Int) -> Int {
    args.count > index ? Int(args[index].number ?? 0) : 0
}

/// An optional string argument. Empty strings mean "not supplied" so JS hosts
/// can pass `""` where a value is absent (as the node/browser seams do).
private func text(_ args: [JSValue], _ index: Int) -> String? {
    guard args.count > index, let string = args[index].string, !string.isEmpty else { return nil }
    return string
}

private func bytes(_ value: JSValue?) -> [UInt8]? {
    guard let value, let array = JSTypedArray<UInt8>(from: value) else { return nil }
    return array.withUnsafeBytes { Array($0) }
}

/// `{ "emo_meta.json": "<json>", "emo_tokenizer.bin": Uint8Array }` -> bytes per
/// name, so a host can pass text sidecars as strings and binary ones as arrays.
private func sidecars(_ value: JSValue?) -> [String: [UInt8]] {
    guard let object = value?.object,
          let keys = JSObject.global.Object.function?.keys?(object).object,
          let count = keys.length.number else { return [:] }
    var out: [String: [UInt8]] = [:]
    for i in 0..<Int(count) {
        guard let name = keys[i].string else { continue }
        let value = object[name]
        if let string = value.string {
            out[name] = Array(string.utf8)
        } else if let blob = bytes(value) {
            out[name] = blob
        }
    }
    return out
}

/// The per-call device id, resolved before the first `await` (a getter must not
/// be called from another call's task tree).
private func collectDeviceId(_ value: JSValue?) -> String? {
    guard let value else { return nil }
    if let string = value.string, !string.isEmpty { return string }
    if let getter = value.function, let string = getter().string, !string.isEmpty { return string }
    return nil
}
#endif
