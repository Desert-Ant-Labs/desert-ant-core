#if os(WASI)
import JavaScriptEventLoop
import JavaScriptKit

/// WebAssembly inference backend, behind the shared ``InferenceSession`` API.
/// The JS host owns the model session (onnxruntime-web / onnxruntime-node /
/// anything tensor-shaped) and exposes one method on a per-model host global:
///
/// ```js
/// globalThis.__MyModelHost = {
///   // inputs/outputs both look like:
///   //   { name: { data: Uint8Array, dims: number[], type: "int64"|"int32"|"float32" } }
///   run: async (inputs) => outputs,
/// };
/// ```
///
/// Bytes cross the wasm boundary raw (host byte order), so the host rebuilds
/// typed arrays from `data.buffer`; no per-element marshalling.
final class JSInferenceSession: InferenceSession, @unchecked Sendable {
    private let runFunction: JSObject
    private let hostGlobal: String

    init(hostGlobal: String, method: String = "run") throws {
        guard let host = JSObject.global[hostGlobal].object, let function = host[method].object else {
            throw InferenceError.sessionUnavailable("missing \(hostGlobal).\(method)")
        }
        runFunction = function
        self.hostGlobal = hostGlobal
    }

    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor] {
        guard let constructor = JSObject.global.Object.function else {
            throw InferenceError.runFailed("no JS Object constructor")
        }
        let object = constructor.new()
        for (name, tensor) in inputs {
            let entry = constructor.new()
            entry.data = JSTypedArray<UInt8>(tensor.bytes).jsValue
            entry.dims = tensor.shape.jsValue
            entry.type = .string(tensor.element.rawValue)
            object[name] = .object(entry)
        }
        guard let promise = runFunction(object.jsValue).object.flatMap(JSPromise.init) else {
            throw InferenceError.runFailed("\(hostGlobal).run did not return a promise")
        }
        let result = try await promise.value
        guard let resultObject = result.object else {
            throw InferenceError.runFailed("\(hostGlobal).run returned no outputs")
        }
        return try outputs.map { name in
            guard let entry = resultObject[name].object,
                  let data = JSTypedArray<UInt8>(from: entry.data),
                  let element = Tensor.Element(rawValue: entry.type.string ?? ""),
                  let dims = entry.dims.object
            else { throw InferenceError.runFailed("\(hostGlobal).run returned no usable '\(name)'") }
            let rank = Int(dims.length.number ?? 0)
            let shape = (0..<rank).compactMap { dims[$0].number.map { Int($0) } }
            return try Tensor(element: element, shape: shape, bytes: data.withUnsafeBytes { Array($0) })
        }
    }
}
#endif
