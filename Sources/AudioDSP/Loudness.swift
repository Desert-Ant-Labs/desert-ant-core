// Loudness measurement and normalization to a delivery target (ITU-R BS.1770-4
// integrated LUFS: K-weighting, 400 ms blocks at 75% overlap, -70/-10 LU
// gating), plus a gain to the target with a peak-safety cap so a master never
// clips. The post-DSP mastering stage audio-output SDKs apply, kept out of the
// model. Accelerate-backed (vDSP_biquad) on Apple, plain Swift elsewhere.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(WASILibc)
import WASILibc
#endif
#if canImport(Accelerate)
import Accelerate
#endif

public enum Loudness {
    // BS.1770-4 K-weighting biquads at 48 kHz (stage 1 high shelf, stage 2 HPF).
    private static let s1b: [Float] = [1.53512485958697, -2.69169618940638, 1.19839281085285]
    private static let s1a: [Float] = [-1.69065929318241, 0.73248077421585]
    private static let s2b: [Float] = [1.0, -2.0, 1.0]
    private static let s2a: [Float] = [-1.99004745483398, 0.99007225036621]

    /// Filters `x` through one biquad stage in place. The K-weighting cascade
    /// runs two of these back to back, and allocating a fresh output per stage
    /// cost two full-signal buffers (726 MB for 33 minutes at 48 kHz).
    private static func biquadInPlace(_ x: inout [Float], _ b: [Float], _ a: [Float]) {
        var delays = [Float](repeating: 0, count: 4)
        biquadInPlace(&x, b, a, delays: &delays)
    }

    /// Filters in place, threading the filter state through `delays` so a
    /// caller can run the same filter over a signal delivered in pieces. The
    /// layout matches `vDSP_biquad`'s: `2 * sections + 2` floats, zeroed to
    /// start a fresh signal.
    fileprivate static func biquadInPlace(_ x: inout [Float], _ b: [Float], _ a: [Float],
                                          delays: inout [Float]) {
        #if canImport(Accelerate)
        let coeffs: [Double] = [Double(b[0]), Double(b[1]), Double(b[2]), Double(a[0]), Double(a[1])]
        // Preserve the old failure behaviour: no filter means no measurement,
        // which the caller reads as silence rather than as unweighted audio.
        guard let setup = vDSP_biquad_CreateSetup(coeffs, 1) else {
            for i in 0..<x.count { x[i] = 0 }
            return
        }
        defer { vDSP_biquad_DestroySetup(setup) }
        // vDSP_biquad permits the same buffer as input and output, and updates
        // `delays` in place so the next call continues the same filter.
        x.withUnsafeMutableBufferPointer { xp in
            vDSP_biquad(setup, &delays, xp.baseAddress!, 1, xp.baseAddress!, 1, vDSP_Length(xp.count))
        }
        #else
        // delays = [x1, x2, y1, y2] in the portable path.
        var x1 = delays[0], x2 = delays[1], y1 = delays[2], y2 = delays[3]
        for i in 0..<x.count {
            let xn = x[i]
            let yn = b[0] * xn + b[1] * x1 + b[2] * x2 - a[0] * y1 - a[1] * y2
            x2 = x1; x1 = xn; y2 = y1; y1 = yn
            x[i] = yn
        }
        delays[0] = x1; delays[1] = x2; delays[2] = y1; delays[3] = y2
        #endif
    }

    /// Integrated loudness in LUFS of mono `samples` at `sampleRate`, or nil for
    /// silence. The K-weighting coefficients are the 48 kHz set (the common
    /// on-device audio rate); pass 48 kHz audio.
    public static func integratedLUFS(_ samples: [Float], sampleRate: Double) -> Double? {
        guard sampleRate == 48_000, samples.count > 0 else { return nil }
        let meter = StreamingMeter(sampleRate: sampleRate)
        guard meter != nil else { return nil }
        meter!.consume(samples)
        return meter!.finalize()
    }

    /// BS.1770-4 integrated loudness over a signal delivered in pieces, so a
    /// caller can measure a long file without ever holding it.
    ///
    /// Feeding the whole signal in one `consume` produces the same number as
    /// ``Loudness/integratedLUFS(_:sampleRate:)`` - that function is now a
    /// wrapper around this - because the K-weighting biquad state carries
    /// across calls and the 400 ms blocks are cut at absolute sample positions,
    /// not at chunk boundaries.
    ///
    /// Not thread safe; feed it from one place.
    public final class StreamingMeter {
        private let block: Int          // 400 ms
        private let step: Int           // 100 ms (75% overlap)

        // K-weighting state, carried across `consume` calls. This is what makes
        // chunked measurement identical to whole-signal measurement.
        private var s1Delays = [Float](repeating: 0, count: 4)
        private var s2Delays = [Float](repeating: 0, count: 4)

        // Weighted samples not yet consumed by a full block. Never longer than
        // `block`, so memory is bounded regardless of signal length.
        private var pending = [Float]()

        // One `Double` pair per 100 ms of signal: about 317 KB per hour, which
        // is small enough to keep for the gating passes.
        private var blockLoud = [Double]()
        private var meanSq = [Double]()

        /// Peak absolute sample seen, for callers that also need peak-ceiling
        /// headroom and would otherwise need a second traversal.
        public private(set) var peak: Float = 0

        /// Returns nil unless `sampleRate` is 48 kHz, which is what the
        /// K-weighting coefficients are derived for.
        public init?(sampleRate: Double) {
            guard sampleRate == 48_000 else { return nil }
            block = Int(0.4 * sampleRate)
            step = Int(0.1 * sampleRate)
            pending.reserveCapacity(block + step)
        }

        /// Feed the next span of samples. Any length is fine.
        public func consume(_ samples: [Float]) {
            samples.withUnsafeBufferPointer { consume($0) }
        }

        public func consume(_ samples: UnsafeBufferPointer<Float>) {
            guard let base = samples.baseAddress, !samples.isEmpty else { return }
            for i in 0..<samples.count { peak = max(peak, abs(base[i])) }

            var weighted = [Float](repeating: 0, count: samples.count)
            weighted.withUnsafeMutableBufferPointer { dp in
                dp.baseAddress!.update(from: base, count: samples.count)
            }
            Loudness.biquadInPlace(&weighted, Loudness.s1b, Loudness.s1a, delays: &s1Delays)
            Loudness.biquadInPlace(&weighted, Loudness.s2b, Loudness.s2a, delays: &s2Delays)

            pending.append(contentsOf: weighted)
            drainBlocks()
        }

        private func drainBlocks() {
            var start = 0
            while start + block <= pending.count {
                var ms: Double
                #if canImport(Accelerate)
                var msF: Float = 0
                pending.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + start, 1, &msF, vDSP_Length(block)) }
                ms = Double(msF)
                #else
                var sum = 0.0
                for i in start..<(start + block) { sum += Double(pending[i]) * Double(pending[i]) }
                ms = sum / Double(block)
                #endif
                meanSq.append(ms)
                blockLoud.append(-0.691 + 10 * log10(ms + 1e-12))
                start += step
            }
            if start > 0 { pending.removeFirst(start) }
        }

        /// The gated integrated loudness, or nil when nothing passed the gate
        /// (silence, or a signal shorter than one 400 ms block).
        public func finalize() -> Double? {
            // Absolute gate -70 LUFS, then relative gate at (gated mean - 10 LU).
            func gatedLoudness(_ threshold: Double) -> Double? {
                var acc = 0.0; var n = 0
                for (i, l) in blockLoud.enumerated() where l > threshold { acc += meanSq[i]; n += 1 }
                return n > 0 ? -0.691 + 10 * log10(acc / Double(n) + 1e-12) : nil
            }
            guard let firstPass = gatedLoudness(-70) else { return nil }
            return gatedLoudness(firstPass - 10) ?? firstPass
        }
    }

    /// Normalize `samples` to `targetLUFS`, capping the applied gain at
    /// `maxGainDB` and never letting the peak exceed `peakCeilingDBFS`. Returns
    /// the normalized samples and the measured input loudness (nil for silence,
    /// left unchanged).
    public static func normalize(_ samples: [Float], sampleRate: Double,
                                 targetLUFS: Double, maxGainDB: Double, peakCeilingDBFS: Double)
        -> (samples: [Float], measuredLUFS: Double?)
    {
        var out = samples
        let lufs = normalizeInPlace(&out, sampleRate: sampleRate, targetLUFS: targetLUFS,
                                    maxGainDB: maxGainDB, peakCeilingDBFS: peakCeilingDBFS)
        return (out, lufs)
    }

    /// `normalize` without the extra output buffer, for callers that own their
    /// signal and can have it rewritten. A full-length master is 363 MB at 33
    /// minutes, and the copy is live alongside the input.
    @discardableResult
    public static func normalizeInPlace(_ samples: inout [Float], sampleRate: Double,
                                        targetLUFS: Double, maxGainDB: Double,
                                        peakCeilingDBFS: Double) -> Double?
    {
        guard let lufs = integratedLUFS(samples, sampleRate: sampleRate) else { return nil }
        // Only upward gain is capped: amplifying a quiet input past the cap
        // would lift the model's noise floor with it, while attenuating a loud
        // one is always safe.
        var gainDB = targetLUFS - lufs
        if gainDB > maxGainDB { gainDB = maxGainDB }
        let gain = Float(pow(10, gainDB / 20))
        for i in 0..<samples.count { samples[i] *= gain }

        // The limiter, not a static backoff, is what holds the ceiling. Backing
        // the whole signal off by `ceiling / peak` would meet the ceiling and
        // miss the loudness target by however far the loudest transient
        // overshot.
        var channels = [samples]
        Limiter.apply(&channels, ceilingDBTP: peakCeilingDBFS, sampleRate: sampleRate)
        samples = channels[0]
        return lufs
    }
}
