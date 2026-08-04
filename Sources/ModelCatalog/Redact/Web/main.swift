#if os(WASI)
import DesertAnt
import JavaScriptEventLoop
import JavaScriptKit
@_spi(RedactBindings) import Redact

// WebAssembly entry point. Mirrors the iOS/Swift SDK (redaction only). The JS
// host must set `globalThis.__RedactHost` (an async LiteRT.js session + runner, see
// `ModelLoading.swift`) before the first redaction. After start, the module
// exposes:
//
//     globalThis.__RedactExports = {
//       load(cacheRoot, directory?, onProgress?)    -> Promise<boolean>,
//       loadBundled(labelsJSON, tokenizerBytes)     -> Promise<boolean>,
//       redaction(text, minimumConfidence, labels?) -> Promise<{redactedText, items}>,
//     }
//
// `packages/redact-node` wraps this in the public typed API; nothing else
// should touch these globals.
JavaScriptEventLoop.installGlobalExecutor()

private nonisolated(unsafe) var redactor: Redact?
private func instance() throws -> Redact {
    guard let redactor else { throw RedactError.resourceMissing }
    return redactor
}

private func parseOptions(_ args: [JSValue]) -> Options {
    let minimum = args.count > 1 ? (args[1].number ?? 0.6) : 0.6
    var labels: Set<Label>?
    if args.count > 2, let arr = args[2].object, let n = arr.length.number {
        labels = Set((0..<Int(n)).compactMap { arr[$0].string.flatMap(Label.init(rawValue:)) })
    }
    return Options(minimumConfidence: minimum, labels: labels)
}

let redactionFn = JSClosure { args in
    let text = args.first?.string ?? ""
    let options = parseOptions(args)
    return JSPromise { resolve in
        Task {
            do {
                let r = try await instance().redaction(of: text, options: options)
                let items = JSObject.global.Array.function!.new()
                for (i, item) in r.items.enumerated() {
                    let o = JSObject.global.Object.function!.new()
                    o.label = .string(item.label.rawValue)
                    o.original = .string(item.original)
                    o.placeholder = .string(item.placeholder)
                    o.confidence = .number(item.confidence)
                    o.start = .number(Double(item.range.lowerBound.utf16Offset(in: text)))
                    o.end = .number(Double(item.range.upperBound.utf16Offset(in: text)))
                    items[i] = .object(o)
                }
                let out = JSObject.global.Object.function!.new()
                out.redactedText = .string(r.redactedText)
                out.items = .object(items)
                resolve(.success(.object(out)))
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
    let redact = Redact(directory: directory, cacheRoot: cacheRoot)
    return JSPromise { resolve in
        Task {
            do {
                try await redact.download { fraction in
                    if let onProgress { _ = onProgress(fraction) }
                }
                redactor = redact
                resolve(.success(.boolean(true)))
            } catch {
                resolve(.failure(.string(String(describing: error))))
            }
        }
    }.jsValue
}

// loadBundled(labelsJSON, tokenizerBytes): wire self-hosted model files (the JS
// host's `modelBaseUrl` opt-out). The host has already compiled the model into
// its LiteRT.js session (createSession/loadAndCompile), so only the labels and
// tokenizer sidecars cross into wasm here; the multi-MB model bytes never do
// (they stay on the JS side).
private func typedArrayBytes(_ value: JSValue?) -> [UInt8]? {
    guard let value, let array = JSTypedArray<UInt8>(from: value) else { return nil }
    return array.withUnsafeBytes { Array($0) }
}

let loadBundledFn = JSClosure { args in
    let labelsJSON = args.first?.string
    let tokenizer = typedArrayBytes(args.count > 1 ? args[1] : nil)
    return JSPromise { resolve in
        Task {
            do {
                guard let labelsJSON, let tokenizer else { throw RedactError.resourceMissing }
                let assets = try ModelAssets(
                    tokenizer: tokenizer, labelsJSON: labelsJSON,
                    session: JSInferenceSession(hostGlobal: "__RedactHost"))
                let redact = Redact(assets: assets)
                try await redact.waitUntilLoaded()
                redactor = redact
                resolve(.success(.boolean(true)))
            } catch {
                resolve(.failure(.string(String(describing: error))))
            }
        }
    }.jsValue
}

let exports = JSObject.global.Object.function!.new()
exports.load = .object(loadFn)
exports.loadBundled = .object(loadBundledFn)
exports.redaction = .object(redactionFn)
JSObject.global.__RedactExports = .object(exports)
#endif
