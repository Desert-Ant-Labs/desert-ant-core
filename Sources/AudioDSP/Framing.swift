// Sliding-window framing and overlap reassembly: the loop every long-audio
// model repeats to run a fixed-size model over an arbitrary-length signal
// (30 s windows with 5 s overlap for a detector, 100-frame chunks for an
// enhancer) and stitch the per-window outputs back together. The model owns
// the inference call; this owns the index math and the averaging.

public enum Framing {
    /// Half-open `[start, end)` window ranges covering `count` items with a
    /// `window`-sized window stepped by `hop`. The final window is clamped to
    /// `count` (so it may be shorter) and the walk stops once it reaches the
    /// end, so there is always at least one window for a non-empty input.
    public static func windows(count: Int, window: Int, hop: Int) -> [(start: Int, end: Int)] {
        guard count > 0, window > 0, hop > 0 else { return [] }
        var out: [(start: Int, end: Int)] = []
        var start = 0
        while start < count {
            let end = min(count, start + window)
            out.append((start, end))
            if end == count { break }
            start += hop
        }
        return out
    }
}

/// Accumulates values written at overlapping offsets and reduces the overlaps.
/// `average()` returns the mean of everything written at each index (overlapping
/// window predictions, e.g. per-frame probabilities); `normalized(by:)` divides
/// the running sum by a parallel weight sum (windowed COLA overlap-add). Fixed
/// length, so out-of-range writes are ignored rather than trapping.
public struct OverlapAccumulator {
    private var sum: [Float]
    private var count: [Float]

    public init(length: Int) {
        sum = [Float](repeating: 0, count: max(0, length))
        count = [Float](repeating: 0, count: max(0, length))
    }

    /// Add `values` starting at `offset`, incrementing each touched index's
    /// count by 1 (or by the matching `weights[i]` when given, for COLA).
    public mutating func add(_ values: [Float], at offset: Int, weights: [Float]? = nil) {
        for i in 0..<values.count {
            let idx = offset + i
            guard idx >= 0, idx < sum.count else { continue }
            sum[idx] += values[i]
            count[idx] += weights?[i] ?? 1
        }
    }

    /// The per-index mean (sum / times-written); indices never written are 0.
    public func average() -> [Float] {
        var out = [Float](repeating: 0, count: sum.count)
        for i in 0..<sum.count where count[i] > 0 { out[i] = sum[i] / count[i] }
        return out
    }

    /// The per-index sum divided by the accumulated weight (COLA), with a small
    /// floor so silent-weight indices stay 0.
    public func normalized(floor: Float = 1e-8) -> [Float] {
        var out = [Float](repeating: 0, count: sum.count)
        for i in 0..<sum.count where count[i] > floor { out[i] = sum[i] / count[i] }
        return out
    }
}
