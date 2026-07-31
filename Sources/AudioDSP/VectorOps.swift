// Small signal-level vector helpers the audio SDKs reach for before/after
// inference: energy normalization (speech enhancement) and per-window mean/std
// standardization (feature models). Accelerate-backed on Apple, plain Swift
// everywhere else, same result either way.

#if canImport(Accelerate)
import Accelerate
#endif

public enum VectorOps {
    /// Sum of squares of `x`.
    public static func energy(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        #if canImport(Accelerate)
        var e: Float = 0
        vDSP_svesq(x, 1, &e, vDSP_Length(x.count))
        return e
        #else
        var e: Float = 0
        for v in x { e += v * v }
        return e
        #endif
    }

    /// Multiply every element by `scalar` (out-of-place).
    public static func scaled(_ x: [Float], by scalar: Float) -> [Float] {
        guard !x.isEmpty else { return x }
        var out = [Float](repeating: 0, count: x.count)
        #if canImport(Accelerate)
        var s = scalar
        vDSP_vsmul(x, 1, &s, &out, 1, vDSP_Length(x.count))
        #else
        for i in 0..<x.count { out[i] = x[i] * scalar }
        #endif
        return out
    }

    /// RMS-energy normalize to unit average power (`gain = sqrt(N / sum x^2)`),
    /// the front-end MP-SENet-style enhancers apply. Returns the normalized
    /// samples and the `gain` used, so the caller can undo it after inference
    /// (`scaled(y, by: 1 / gain)`). A silent input is returned unchanged with
    /// `gain == 1`.
    public static func energyNormalize(_ x: [Float]) -> (samples: [Float], gain: Float) {
        let e = energy(x)
        let gain = e > 0 ? (Float(x.count) / e).squareRoot() : 1
        return (scaled(x, by: gain), gain)
    }

    /// Standardize to zero mean and unit variance (sample std, `+ eps`), the
    /// per-window normalization raw-waveform classifiers expect. Matches a
    /// training-time `(x - mean) / (std + eps)` with an unbiased std.
    public static func standardize(_ x: [Float], eps: Float = 1e-7) -> [Float] {
        guard x.count > 1 else { return x }
        let n = Float(x.count)
        var mean: Float = 0
        for v in x { mean += v }
        mean /= n
        var sumSq: Float = 0
        for v in x { let d = v - mean; sumSq += d * d }
        let std = (sumSq / (n - 1)).squareRoot() + eps
        let inv = 1 / std
        var out = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count { out[i] = (x[i] - mean) * inv }
        return out
    }
}
