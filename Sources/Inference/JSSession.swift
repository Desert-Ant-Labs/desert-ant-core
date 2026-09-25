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
    /// Which of the host's compiled models, and which of its signatures. `nil`
    /// is the module's one model through `run`, which is every single-graph
    /// model; a handle comes from `loadModelFrom*` (see `Host.swift`).
    private let model: Int?
    private let signature: String

    public init() {
        model = nil
        signature = ""
    }

    /// A session over one signature of a model the host compiled. Handle 0 is
    /// the module's own model (the one `run` uses), so a self-hosted model's
    /// signatures are reachable through it.
    public init(model: Int, signature: String?) {
        self.model = model
        self.signature = signature ?? ""
    }

    public func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor] {
        let feeds = inputs.mapValues {
            HostTensor(data: JSUint8Array($0.bytes), dims: $0.shape, type: $0.element.rawValue)
        }
        let results: [String: HostTensor]
        do {
            if let model {
                results = try await dalModelHost.runModel(model, signature, feeds)
            } else {
                results = try await dalModelHost.run(feeds)
            }
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
