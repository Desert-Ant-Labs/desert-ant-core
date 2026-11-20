#if os(WASI)
import JSHost
import JavaScriptEventLoop
import JavaScriptKit

/// WebAssembly inference backend, behind the shared ``InferenceSession`` API.
///
/// The JS host owns the LiteRT.js session; this drives it through the typed
/// contract in `JSHost` (`Sources/JSHost/Host.swift`), whose TypeScript type the
/// host must satisfy. Tensor bytes cross the wasm boundary raw, so neither side
/// marshals per element. `model` names which of the host's compiled models to
/// run: the loaded instance's namespace, then the artifact's cached path, or for
/// files the page fetched itself, the file name (empty for the artifact); with a `signature`, the
/// session runs that signature of it, so one compiled model serves several
/// sessions.
public final class JSInferenceSession: InferenceSession, @unchecked Sendable {
    /// Prefixes the name of every model compiled and every session created while it is set: unique to the loaded
    /// instance (`h<handle>/`, or the prefix a page chose for the files it fetched itself), so no instance ever runs,
    /// replaces or frees another's model.
    @TaskLocal public static var namespace = ""

    private let model: String
    private let signature: String?

    public init(model: String = "", signature: String? = nil) {
        self.model = Self.namespace + model
        self.signature = signature
    }

    public func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor] {
        let feeds = inputs.mapValues {
            HostTensor(data: JSUint8Array($0.bytes), dims: $0.shape, type: $0.element.rawValue)
        }
        let results: [String: HostTensor]
        do {
            if let signature {
                results = try await dalModelHost.runSignature(signature, feeds, model)
            } else {
                results = try await dalModelHost.run(feeds, model)
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
