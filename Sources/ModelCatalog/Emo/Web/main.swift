#if os(WASI)
import DesertAnt
import JavaScriptEventLoop
import JavaScriptKit
@_spi(EmoBindings) import Emo

// WebAssembly entry point. Mirrors the iOS/Swift SDK (suggestion only). The JS
// host must set `globalThis.__EmoHost` (an async LiteRT.js session + runner, see
// desert-ant-core's JSInferenceSession) before the first suggestion. After
// start, the module exposes:
//
//     globalThis.__EmoExports = {
//       load(cacheRoot, directory?, onProgress?)          -> Promise<boolean>,
//       loadBundled(metaJSON, tokenizerBytes, modelBytes) -> Promise<boolean>,
//       suggest(text, limit?, skinTone?, deviceId?)       -> Promise<[{emoji, confidence}]>,
//     }
//
// `deviceId` may be a string or a zero-arg function returning one; it is
// collected per call and bound to that call's task tree (safe for concurrent
// multi-tenant hosts), attributing usage to a specific end-user device.
//
// `skinTone` is a number: 0 default, 1 light, 2 mediumLight, 3 medium,
// 4 mediumDark, 5 dark. `packages/emo-node` wraps this in the public typed API;
// nothing else should touch these globals.
JavaScriptEventLoop.installGlobalExecutor()

private nonisolated(unsafe) var suggester: Emo?
private func instance() throws -> Emo {
    guard let suggester else { throw EmoError.modelNotFound }
    return suggester
}

private func skinTone(_ raw: Double?) -> EmojiSkinTone {
    switch Int(raw ?? 0) {
    case 1: return .light
    case 2: return .mediumLight
    case 3: return .medium
    case 4: return .mediumDark
    case 5: return .dark
    default: return .default
    }
}

private func encode(_ suggestions: [EmoSuggestion]) -> JSValue {
    let arr = JSObject.global.Array.function!.new()
    for (i, s) in suggestions.enumerated() {
        let o = JSObject.global.Object.function!.new()
        o.emoji = .string(s.emoji)
        o.confidence = .number(s.confidence)
        arr[i] = .object(o)
    }
    return .object(arr)
}

private func collectDeviceId(_ value: JSValue?) -> String? {
    guard let value else { return nil }
    if let string = value.string, !string.isEmpty { return string }
    if let getter = value.function, let string = getter().string, !string.isEmpty { return string }
    return nil
}

let suggestFn = JSClosure { args in
    let text = args.first?.string ?? ""
    let limit = args.count > 1 ? Int(args[1].number ?? 3) : 3
    let tone = skinTone(args.count > 2 ? args[2].number : nil)
    // Collect the per-call device id now (before any await), then bind it to
    // this call's task tree so concurrent calls stay isolated.
    let deviceId = collectDeviceId(args.count > 3 ? args[3] : nil)
    return JSPromise { resolve in
        Task {
            do {
                let suggestions = try await InferenceContext.$deviceId.withValue(deviceId) {
                    try await instance().suggestions(for: text, limit: limit, skinTone: tone)
                }
                resolve(.success(encode(suggestions)))
            } catch {
                resolve(.failure(.string(String(describing: error))))
            }
        }
    }.jsValue
}

// load(cacheRoot, directory, onProgress?): the repo and revision are pinned to
// the SDK. `cacheRoot` is the base for the managed nested cache (node `~/.cache`;
// empty in the browser). `directory`, when non-empty, is an explicit model
// directory (adopt files there, else download into it). `onProgress`, when a
// function, is called with the download fraction in [0, 1].
let loadFn = JSClosure { args in
    let cacheRoot = args.first?.string.flatMap { $0.isEmpty ? nil : $0 }
    let directory = (args.count > 1 ? args[1].string : nil).flatMap { $0.isEmpty ? nil : $0 }
    let onProgress: JSFunction? = args.count > 2 ? args[2].function : nil
    let emo = Emo(directory: directory, cacheRoot: cacheRoot)
    return JSPromise { resolve in
        Task {
            do {
                try await emo.download { fraction in
                    if let onProgress { _ = onProgress(fraction) }
                }
                suggester = emo
                resolve(.success(.boolean(true)))
            } catch {
                resolve(.failure(.string(String(describing: error))))
            }
        }
    }.jsValue
}

// loadBundled(metaJSON, tokenizerBytes): wire self-hosted model files (the JS
// host's `modelBaseUrl` opt-out). The host has already compiled the model into
// its LiteRT.js session (createSession/loadAndCompile), so only the metadata
// and tokenizer sidecars cross into wasm here; the multi-MB model bytes never
// do (they stay on the JS side).
private func typedArrayBytes(_ value: JSValue?) -> [UInt8]? {
    guard let value, let array = JSTypedArray<UInt8>(from: value) else { return nil }
    return array.withUnsafeBytes { Array($0) }
}

let loadBundledFn = JSClosure { args in
    let metaJSON = args.first?.string
    let tokenizer = typedArrayBytes(args.count > 1 ? args[1] : nil)
    return JSPromise { resolve in
        Task {
            do {
                guard let metaJSON, let tokenizer else { throw EmoError.modelNotFound }
                let assets = try ModelAssets(
                    metaJSON: metaJSON, tokenizer: tokenizer,
                    session: inferenceSession(hostGlobal: "__EmoHost"))
                let emo = Emo(assets: assets)
                try await emo.waitUntilLoaded()
                suggester = emo
                resolve(.success(.boolean(true)))
            } catch {
                resolve(.failure(.string(String(describing: error))))
            }
        }
    }.jsValue
}

// flushTelemetry(): force any tracked session to emit now (bypassing the 3s
// debounce + re-emit window) and await the send, so the usage POST actually
// goes out before the caller continues. Requires `globalThis.__dalHttpDebug`.
let flushTelemetryFn = JSClosure { _ in
    JSPromise { resolve in
        Task {
            await TelemetryDebug.shared.flushAndWait()
            resolve(.success(.boolean(true)))
        }
    }.jsValue
}

let exports = JSObject.global.Object.function!.new()
exports.load = .object(loadFn)
exports.loadBundled = .object(loadBundledFn)
exports.suggest = .object(suggestFn)
exports.flushTelemetry = .object(flushTelemetryFn)
JSObject.global.__EmoExports = .object(exports)
#endif
