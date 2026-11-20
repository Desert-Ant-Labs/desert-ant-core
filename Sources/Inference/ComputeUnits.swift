/// Which compute units an on-device backend may use. Maps to Core ML's
/// `MLComputeUnits` on Apple. LiteRT only honors `.cpuOnly`, which keeps it off
/// the GPU; the ONNX and JS backends ignore it (they pick their own execution
/// providers). Model SDKs pass it through the session factory so they need not
/// import CoreML to pin, e.g., `.cpuAndNeuralEngine`.
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

/// The arithmetic LiteRT's GPU accelerator runs a model in (its
/// `LiteRtDelegatePrecision`). Core ML, ONNX and the JS backends ignore it, and
/// so do CPU sessions. Package-only: a model SDK picks one for its graph.
package enum GPUPrecision: Int32, Sendable {
    /// fp16 math with fp32 accumulation. LiteRT's own default accumulates in fp16
    /// too, which on Adreno moved Eye's photo heads far off the CPU (issue #101);
    /// this brings them back for about a quarter more GPU time there.
    case fp16WithFp32Accumulation = 3
    /// fp32 throughout, for a graph whose outputs still drift too far at fp16
    /// with fp32 accumulation (Toxic's heads on Adreno).
    case fp32 = 2
}
