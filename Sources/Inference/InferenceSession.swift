/// Errors from building or running an inference session.
public enum InferenceError: Error, Sendable {
    case invalidTensor(String)
    case sessionUnavailable(String)
    case runFailed(String)

    public var message: String {
        switch self {
        case .invalidTensor(let detail): return "Invalid tensor: \(detail)"
        case .sessionUnavailable(let detail): return "Inference session unavailable: \(detail)"
        case .runFailed(let detail): return "Inference failed: \(detail)"
        }
    }
}

/// One loaded model you can run: named input tensors in, the requested output
/// tensors back (in the order asked). The backends behind it:
///
/// - Apple platforms: ``CoreMLSession`` (Core ML).
/// - Android / Linux: ``ORTSession`` (ONNX Runtime C API).
/// - WebAssembly: ``JSInferenceSession`` (the JS host owns the session,
///   e.g. onnxruntime-web / onnxruntime-node).
///
/// Sessions are expensive to create and cheap to run: create one per model and
/// reuse it. Autoregressive models feed outputs back as the next step's
/// inputs. `run` is async because the JS backend awaits a Promise; the native
/// backends satisfy it synchronously. Sessions are `Sendable`: their state is
/// set once at init, and the underlying runtimes' run calls are thread-safe
/// (`MLModel.prediction`, `OrtApi.Run`; wasm is single-threaded).
public protocol InferenceSession: Sendable {
    func run(inputs: [String: Tensor], outputs: [String]) async throws -> [Tensor]
}
