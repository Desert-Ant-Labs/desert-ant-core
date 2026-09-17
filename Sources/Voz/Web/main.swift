#if os(WASI)
import Foundation
import JavaScriptEventLoop
import JavaScriptKit
@_spi(VozWeb) import Voz

// Voz's WebAssembly entry point.
//
// The same `Pipeline` the Neural Engine runs: windowing, the boundary search,
// the lane-batched decode and the splice are Swift on both platforms, and the
// only thing that differs is the engine underneath (`Engine+Wasm.swift`), which
// calls back into JavaScript to run the three models.
//
// The surface is deliberately small - load once, then transcribe a Float32Array
// - because everything else a browser needs (fetching the bundle, compiling the
// models, choosing an execution provider) is the JS host's business and it is
// better at it.

JavaScriptEventLoop.installGlobalExecutor()

/// The loaded recogniser, kept alive between calls.
private var voz: Voz?

/// `__vozLoad(meta, vocab, embedding, lanes)` - the sidecars, as bytes the host
/// already fetched, and the lane count its decode model was exported with.
let load = JSClosure { arguments in
    let promise = JSPromise { resolve in
        Task {
            do {
                func bytes(_ index: Int) throws -> Data {
                    guard index < arguments.count,
                          let array = JSTypedArray<UInt8>(from: arguments[index]) else {
                        throw VozError.invalidModel("argument \(index) is not a Uint8Array")
                    }
                    return array.withUnsafeBytes { Data($0) }
                }
                // Indexing past the end of the argument list traps, and a host
                // that passes fewer arguments than the current build expects is
                // a normal thing to happen while both sides are moving.
                func argument(_ index: Int) -> JSValue {
                    index < arguments.count ? arguments[index] : .undefined
                }
                guard let lanes = Int(exactly: argument(3).number ?? 0),
                      let batch = Int(exactly: argument(4).number ?? 1) else {
                    throw VozError.invalidModel("lane and batch counts must be integers")
                }
                let fused = argument(5).boolean ?? false
                voz = try await Voz.web(meta: try bytes(0), vocab: try bytes(1),
                                        embedding: try bytes(2), lanes: lanes,
                                        batch: batch, fused: fused)
                resolve(.success(.boolean(true)))
            } catch {
                resolve(.failure(.string("\(error)")))
            }
        }
    }
    return .object(promise.jsObject)
}
JSObject.global.__vozLoad = .object(load)

/// `__vozTranscribe(samples)` - mono 16 kHz Float32Array in, transcript out.
let transcribe = JSClosure { arguments in
    let promise = JSPromise { resolve in
        Task {
            do {
                guard let voz else { throw VozError.invalidModel("not loaded") }
                guard let first = arguments.first,
                      let samples = JSTypedArray<Float>(from: first) else {
                    throw VozError.invalidAudio("expected a Float32Array")
                }
                let audio = samples.withUnsafeBytes { Array($0) }
                let result = try await voz.transcribe(samples: audio)
                let out = JSObject.global.Object.function!.new()
                out.text = .string(result.text)
                out.duration = .number(result.duration)
                out.processingTime = .number(result.processingTime)
                out.words = .number(Double(result.words.count))
                resolve(.success(.object(out)))
            } catch {
                resolve(.failure(.string("\(error)")))
            }
        }
    }
    return .object(promise.jsObject)
}
JSObject.global.__vozTranscribe = .object(transcribe)

JSObject.global.__vozReady = .boolean(true)
#endif
