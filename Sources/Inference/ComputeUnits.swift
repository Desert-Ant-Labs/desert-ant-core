/// Which compute units an on-device backend may use. Maps to Core ML's
/// `MLComputeUnits` on Apple; the ONNX/LiteRT/JS backends ignore it (they pick
/// their own execution providers). Model SDKs pass it through the session
/// factory so they need not import CoreML to pin, e.g., `.cpuAndNeuralEngine`.
///
/// Choosing: `.all` lets Core ML use CPU+GPU+ANE, but for a small-op-dense
/// graph the GPU is often slow and, if any op forces a CPU fallback (e.g. a
/// `while_loop`), the extra partitioning can make `.all` slower than
/// `.cpuOnly`. ANE-friendly graphs (no dynamic control flow) are usually
/// fastest on `.cpuAndNeuralEngine`.
public enum ComputeUnits: Sendable {
    /// CPU + GPU + Neural Engine; Core ML partitions across them.
    case all
    /// CPU + Neural Engine (skips the GPU). Often fastest on ANE-native graphs.
    case cpuAndNeuralEngine
    /// CPU only. Deterministic fallback / diagnostic.
    case cpuOnly
}
