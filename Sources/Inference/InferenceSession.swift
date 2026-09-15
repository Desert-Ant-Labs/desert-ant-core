// Re-exported so SDKs importing `Inference` (for the session factory) also get
// the usage wire types (`SDKInfo`, `IngestBody`, ...) without a separate import.
@_exported import Usage

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
/// - Android / Linux: ``LiteRTSession``.
/// - WebAssembly: ``JSInferenceSession`` (the JS host owns the LiteRT session).
///
/// Sessions are expensive to create and cheap to run: create one per model and
/// reuse it. Autoregressive models feed outputs back as the next step's
/// inputs. `run` is async because the JS backend awaits a Promise; the native
/// backends satisfy it synchronously. Sessions are `Sendable`: their state is
/// set once at init; Core ML is reentrant, LiteRT runs are serialized around
/// its fixed buffers, and wasm is single-threaded.
public protocol InferenceSession: Sendable {
    /// Run the model. `deviceId` attributes usage to a specific end-user device
    /// for multi-tenant hosts (e.g. a server serving many users); `nil` uses the
    /// default device (the app's persisted id, or a host-provided one). The
    /// concrete backends ignore it — only the usage-tracking wrapper uses it.
    /// Most callers use the two-argument convenience below.
    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor]

    /// Run several independent inputs in one submission.
    ///
    /// The Neural Engine charges a fixed cost per dispatch - the host request,
    /// the firmware round trip, the completion - and a caller handing it one
    /// input at a time pays that per item while the engine idles through it. A
    /// batch hands the runtime the whole queue at once, so it can run the items
    /// back to back and, on a machine with more than one engine, across both.
    ///
    /// Measured on the models this package ships, Neural Engine only, ms per
    /// item at a batch of four against one at a time:
    ///
    ///                  M5 (1 engine)   M3 Ultra (2 engines)
    ///   uhm             79.3 -> 56.1    93.6 -> 36.6
    ///   voz encoder     25.4 -> 25.1    30.3 -> 13.8
    ///
    /// Item i of a batch is bit-identical to predicting it alone; that was
    /// checked on every compiled model here before this existed.
    ///
    /// The default is the loop it replaces, which is what the runtimes without a
    /// batch path (LiteRT, the JS host) want anyway.
    ///
    /// A requirement rather than an extension: a method that only exists in an
    /// extension binds statically, so every call through `any InferenceSession`
    /// would reach the default below and no backend could ever replace it. That
    /// is not hypothetical - it is what this looked like for its first hour, and
    /// it measured exactly no difference.
    func run(batch: [[String: Tensor]], outputs: [String]) async throws -> [[Tensor]]

    /// The last-dimension extent this graph was compiled at for a named input — its sequence
    /// width — or `nil` when the runtime cannot report shapes.
    ///
    /// Exists so a caller can size buffers from the ARTIFACT rather than from a constant. The
    /// clips scorer forced it: two candidate packages differ in exactly this number (`score` at
    /// [16,128] against [16,256]) and in nothing else about their I/O, so a hardcoded width
    /// silently truncates every candidate on the wider one and reports no difference between
    /// them — a null by construction rather than a measurement.
    func inputWidth(_ name: String) -> Int?
}

public extension InferenceSession {
    /// One at a time, which is what a runtime without a batch path (LiteRT, the
    /// JS host) does anyway, and what every backend did before this existed.
    func run(batch: [[String: Tensor]], outputs: [String]) async throws -> [[Tensor]] {
        var results: [[Tensor]] = []
        results.reserveCapacity(batch.count)
        for inputs in batch { results.append(try await run(inputs: inputs, outputs: outputs)) }
        return results
    }

    /// Runtimes that cannot introspect their own shapes report nothing, and callers fall back
    /// to their own default. Returning `nil` rather than a guess keeps "I don't know" distinct
    /// from "it is 128".
    func inputWidth(_ name: String) -> Int? { nil }

    /// Run, resolving the device id for usage attribution without the SDK having
    /// to pass one. Precedence:
    ///   1. `InferenceContext.deviceId` — a per-call task-local the host binds
    ///      around this call (the correct path for concurrent multi-tenant hosts).
    ///   2. `hostProvidedDeviceId()` — a host default (`globalThis.__dalDeviceId`
    ///      on WASI; native host id elsewhere).
    ///   3. `nil` — the app's persisted/default device, resolved downstream.
    func run(inputs: [String: Tensor], outputs: [String]) async throws -> [Tensor] {
        let deviceId = InferenceContext.deviceId ?? hostProvidedDeviceId()
        return try await run(inputs: inputs, outputs: outputs, deviceId: deviceId)
    }
}
