#if os(WASI)
import JavaScriptEventLoop
import JavaScriptKit

// WebAssembly decode backend: the JS host owns audio decoding and exposes one
// method on the `__DalAudioHost` global, mirroring the JS inference session.
// desert-ant-core's own npm package installs it, so a model SDK writes no JS:
//
//   import { installAudioHost } from "@desert-ant-labs/core";        // browser: Web Audio
//   import { installAudioHost } from "@desert-ant-labs/core/node";   // node: WAV codec
//   installAudioHost();   // sets globalThis.__DalAudioHost.decode(path, bytes, sampleRate)
//
// `path` is a string on node, null in the browser; `bytes` is the file's
// Uint8Array in the browser, null on node. It returns mono Float32 at `rate`.
// Bytes cross the wasm boundary raw; the host returns a Float32Array we copy in.

extension AudioIO {
    static func jsDecode(path: String?, bytes: [UInt8]?, sampleRate: Double) async throws -> [Float] {
        guard let host = JSObject.global.__DalAudioHost.object,
              let decode = host.decode.function else {
            throw AudioIOError.unsupported("missing __DalAudioHost.decode")
        }
        let pathArg: JSValue = path.map { .string($0) } ?? .null
        let bytesArg: JSValue = bytes.map { JSTypedArray<UInt8>($0).jsValue } ?? .null
        let result = decode(this: host, pathArg, bytesArg, JSValue.number(sampleRate))
        guard let promise = result.object.flatMap(JSPromise.init) else {
            throw AudioIOError.decodeFailed("__DalAudioHost.decode did not return a promise")
        }
        let value = try await promise.value
        guard let floats = JSTypedArray<Float>(from: value) else {
            throw AudioIOError.decodeFailed("__DalAudioHost.decode returned no Float32Array")
        }
        return floats.withUnsafeBytes { Array($0) }
    }
}
#endif
