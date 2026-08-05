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

    private static func biquad(_ x: [Float], _ b: [Float], _ a: [Float]) -> [Float] {
        var y = [Float](repeating: 0, count: x.count)
        #if canImport(Accelerate)
        let coeffs: [Double] = [Double(b[0]), Double(b[1]), Double(b[2]), Double(a[0]), Double(a[1])]
        guard let setup = vDSP_biquad_CreateSetup(coeffs, 1) else { return y }
        defer { vDSP_biquad_DestroySetup(setup) }
        var delays = [Float](repeating: 0, count: 2 + 2)
        x.withUnsafeBufferPointer { xp in
            y.withUnsafeMutableBufferPointer { yp in
                vDSP_biquad(setup, &delays, xp.baseAddress!, 1, yp.baseAddress!, 1, vDSP_Length(x.count))
            }
        }
        #else
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        for i in 0..<x.count {
            let xn = x[i]
            let yn = b[0] * xn + b[1] * x1 + b[2] * x2 - a[0] * y1 - a[1] * y2
            x2 = x1; x1 = xn; y2 = y1; y1 = yn
            y[i] = yn
        }
        #endif
        return y
    }

    /// Integrated loudness in LUFS of mono `samples` at `sampleRate`, or nil for
    /// silence. The K-weighting coefficients are the 48 kHz set (the common
    /// on-device audio rate); pass 48 kHz audio.
    public static func integratedLUFS(_ samples: [Float], sampleRate: Double) -> Double? {
        guard sampleRate == 48_000, samples.count > 0 else { return nil }
        let weighted = biquad(biquad(samples, s1b, s1a), s2b, s2a)
        let block = Int(0.4 * sampleRate)      // 400 ms
        let step = Int(0.1 * sampleRate)       // 100 ms (75% overlap)
        guard weighted.count >= block else { return nil }

        var blockLoud: [Double] = []
        var meanSq: [Double] = []
        var start = 0
        while start + block <= weighted.count {
            var ms: Double
            #if canImport(Accelerate)
            var msF: Float = 0
            weighted.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + start, 1, &msF, vDSP_Length(block)) }
            ms = Double(msF)
            #else
            var sum = 0.0
            for i in start..<(start + block) { sum += Double(weighted[i]) * Double(weighted[i]) }
            ms = sum / Double(block)
            #endif
            meanSq.append(ms)
            blockLoud.append(-0.691 + 10 * log10(ms + 1e-12))
            start += step
        }
        // Absolute gate -70 LUFS, then relative gate at (gated mean - 10 LU).
        func gatedLoudness(_ threshold: Double) -> Double? {
            var acc = 0.0; var n = 0
            for (i, l) in blockLoud.enumerated() where l > threshold { acc += meanSq[i]; n += 1 }
            return n > 0 ? -0.691 + 10 * log10(acc / Double(n) + 1e-12) : nil
        }
        guard let firstPass = gatedLoudness(-70) else { return nil }
        return gatedLoudness(firstPass - 10) ?? firstPass
    }

    /// Normalize `samples` to `targetLUFS`, capping the applied gain at
    /// `maxGainDB` and never letting the peak exceed `peakCeilingDBFS`. Returns
    /// the normalized samples and the measured input loudness (nil for silence,
    /// left unchanged).
    public static func normalize(_ samples: [Float], sampleRate: Double,
                                 targetLUFS: Double, maxGainDB: Double, peakCeilingDBFS: Double)
        -> (samples: [Float], measuredLUFS: Double?)
    {
        guard let lufs = integratedLUFS(samples, sampleRate: sampleRate) else { return (samples, nil) }
        var gainDB = targetLUFS - lufs
        if gainDB > maxGainDB { gainDB = maxGainDB }
        var gain = Float(pow(10, gainDB / 20))

        var peak: Float = 0
        for v in samples { peak = max(peak, abs(v)) }
        let ceiling = Float(pow(10, peakCeilingDBFS / 20))
        if peak * gain > ceiling, peak > 0 { gain = ceiling / peak }

        var out = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count { out[i] = max(-1, min(1, samples[i] * gain)) }
        return (out, lufs)
    }
}
