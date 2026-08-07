#if os(WASI)
import JSHost
import JavaScriptEventLoop
import JavaScriptKit

/// WebAssembly inference backend, behind the shared ``InferenceSession`` API.
///
/// The JS host owns the LiteRT.js session; this drives it through the typed
/// contract in `JSHost` (`Sources/JSHost/Host.swift`), whose TypeScript type the
/// host must satisfy. Tensor bytes cross the wasm boundary raw, so neither side
/// marshals per element.
public final class JSInferenceSession: InferenceSession, @unchecked Sendable {
    public init() {}

    public func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor] {
        let feeds = inputs.mapValues {
            HostTensor(data: JSUint8Array($0.bytes), dims: $0.shape, type: $0.element.rawValue)
        }
        let results: [String: HostTensor]
        do {
            results = try await dalModelHost.run(feeds)
        } catch {
            throw InferenceError.runFailed("the host failed to run the model: \(error)")
        }
        return try outputs.map { name in
            guard let tensor = results[name],
                  let element = Tensor.Element(rawValue: tensor.type)
            else { throw InferenceError.runFailed("the host returned no usable '\(name)'") }
            return try Tensor(
                element: element, shape: tensor.dims,
                bytes: tensor.data.withUnsafeBytes { Array($0) })
        }
    }
}
#endif
