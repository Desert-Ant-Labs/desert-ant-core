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
#elseif os(Windows)
import CRT
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

        /// How many channels this meter was built for.
        public let channelCount: Int

        // K-weighting state, one filter pair per channel, carried across
        // `consume` calls. This is what makes chunked measurement identical to
        // whole-signal measurement.
        private var s1Delays: [[Float]]
        private var s2Delays: [[Float]]

        // Weighted samples not yet consumed by a full block, per channel. Never
        // longer than `block`, so memory is bounded regardless of signal length.
        private var pending: [[Float]]

        // One `Double` pair per 100 ms of signal: about 317 KB per hour, which
        // is small enough to keep for the gating passes.
        private var blockLoud = [Double]()
        private var meanSq = [Double]()
        // Per-channel block mean squares, kept only when a caller asks for
        // per-channel loudness (channel balancing); nil otherwise, so the mono
        // and stereo mastering paths pay nothing for a number they never read.
        private var perChannelMeanSq: [[Double]]?

        /// Peak absolute sample seen across every channel, for callers that also
        /// need peak-ceiling headroom and would otherwise need a second
        /// traversal.
        public private(set) var peak: Float = 0

        /// Returns nil unless `sampleRate` is 48 kHz, which is what the
        /// K-weighting coefficients are derived for.
        public convenience init?(sampleRate: Double) {
            self.init(sampleRate: sampleRate, channels: 1)
        }

        /// A meter over `channels` interleaved-by-array streams. BS.1770 weights
        /// left and right at 1.0 and sums their mean squares per block, which is
        /// what makes a stereo programme measure louder than either side alone.
        public init?(sampleRate: Double, channels: Int, perChannel: Bool = false) {
            guard sampleRate == 48_000, channels > 0 else { return nil }
            channelCount = channels
            s1Delays = Array(repeating: [Float](repeating: 0, count: 4), count: channels)
            s2Delays = Array(repeating: [Float](repeating: 0, count: 4), count: channels)
            pending = Array(repeating: [Float](), count: channels)
            if perChannel { perChannelMeanSq = Array(repeating: [Double](), count: channels) }
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
            weight(base, count: samples.count, channel: 0)
            drainBlocks()
        }

        /// Feed the next span of every channel. All of them must be the same
        /// length: the 400 ms blocks are cut at one absolute position shared by
        /// the whole programme, not per channel.
        public func consume(_ channels: [[Float]]) {
            guard let n = channels.first?.count, n > 0, channels.count == channelCount else { return }
            for c in 0..<channelCount {
                channels[c].withUnsafeBufferPointer { weight($0.baseAddress!, count: n, channel: c) }
            }
            drainBlocks()
        }

        /// K-weight one channel's span and park it in that channel's pending.
        private func weight(_ base: UnsafePointer<Float>, count: Int, channel c: Int) {
            for i in 0..<count { peak = max(peak, abs(base[i])) }

            var weighted = [Float](repeating: 0, count: count)
            weighted.withUnsafeMutableBufferPointer { dp in
                dp.baseAddress!.update(from: base, count: count)
            }
            Loudness.biquadInPlace(&weighted, Loudness.s1b, Loudness.s1a, delays: &s1Delays[c])
            Loudness.biquadInPlace(&weighted, Loudness.s2b, Loudness.s2a, delays: &s2Delays[c])

            pending[c].append(contentsOf: weighted)
        }

        /// Mean square of `pending[c]` over one block starting at `start`.
        private func blockMeanSquare(_ c: Int, from start: Int) -> Double {
            #if canImport(Accelerate)
            var msF: Float = 0
            pending[c].withUnsafeBufferPointer {
                vDSP_measqv($0.baseAddress! + start, 1, &msF, vDSP_Length(block))
            }
            return Double(msF)
            #else
            var sum = 0.0
            for i in start..<(start + block) { sum += Double(pending[c][i]) * Double(pending[c][i]) }
            return sum / Double(block)
            #endif
        }

        private func drainBlocks() {
            var start = 0
            // Every channel is fed the same length, so their pendings stay in
            // lockstep and one loop bound serves all of them.
            while start + block <= pending[0].count {
                // BS.1770 sums the weighted mean squares across channels (L and
                // R both weight 1.0), so a block's loudness is the programme's,
                // not one channel's.
                var ms = 0.0
                for c in 0..<channelCount {
                    let channelMS = blockMeanSquare(c, from: start)
                    ms += channelMS
                    perChannelMeanSq?[c].append(channelMS)
                }
                meanSq.append(ms)
                blockLoud.append(-0.691 + 10 * log10(ms + 1e-12))
                start += step
            }
            if start > 0 {
                for c in 0..<channelCount { pending[c].removeFirst(start) }
            }
        }

        /// The gated integrated loudness, or nil when nothing passed the gate
        /// (silence, or a signal shorter than one 400 ms block).
        public func finalize() -> Double? {
            Self.gated(blockLoud: blockLoud, meanSq: meanSq)
        }

        /// Each channel's own integrated loudness, gated on that channel
        /// alone; empty unless built with `perChannel: true`. What channel
        /// balancing needs, and what ``finalize()`` cannot express.
        public func finalizePerChannel() -> [Double?] {
            guard let perChannelMeanSq else { return [] }
            return perChannelMeanSq.map { channelMS in
                let loud = channelMS.map { -0.691 + 10 * log10($0 + 1e-12) }
                return Self.gated(blockLoud: loud, meanSq: channelMS)
            }
        }

        /// BS.1770 gating: absolute at -70 LUFS, then relative at (gated mean
        /// - 10 LU).
        private static func gated(blockLoud: [Double], meanSq: [Double]) -> Double? {
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

    /// Integrated loudness of a multi-channel programme, or nil for silence.
    /// One channel gives the same number as the mono entry point.
    public static func integratedLUFS(_ channels: [[Float]], sampleRate: Double) -> Double? {
        guard let n = channels.first?.count, n > 0,
              let meter = StreamingMeter(sampleRate: sampleRate, channels: channels.count)
        else { return nil }
        meter.consume(channels)
        return meter.finalize()
    }

    /// ``normalizeInPlace(_:sampleRate:targetLUFS:maxGainDB:peakCeilingDBFS:)``
    /// over a multi-channel programme.
    ///
    /// Gain and limiter are both joint, so mastering never moves the stereo
    /// image. `balanceChannelsLUFS` is the exception: it runs first, per
    /// channel, and the joint stages then see one corrected programme.
    @discardableResult
    public static func normalizeInPlace(_ channels: inout [[Float]], sampleRate: Double,
                                        targetLUFS: Double, maxGainDB: Double,
                                        peakCeilingDBFS: Double,
                                        balanceChannelsLUFS: Double? = nil) -> Double?
    {
        guard let n = channels.first?.count, n > 0 else { return nil }

        if let balanceTarget = balanceChannelsLUFS, channels.count > 1 {
            guard let meter = StreamingMeter(sampleRate: sampleRate,
                                             channels: channels.count, perChannel: true)
            else { return nil }
            meter.consume(channels)
            for (c, measured) in meter.finalizePerChannel().enumerated() {
                guard let measured, measured.isFinite else { continue }
                let gain = Float(pow(10, (balanceTarget - measured) / 20))
                for i in 0..<n { channels[c][i] *= gain }
            }
        }

        guard let lufs = integratedLUFS(channels, sampleRate: sampleRate) else { return nil }
        var gainDB = targetLUFS - lufs
        if gainDB > maxGainDB { gainDB = maxGainDB }
        let gain = Float(pow(10, gainDB / 20))
        for c in 0..<channels.count {
            for i in 0..<n { channels[c][i] *= gain }
        }

        Limiter.apply(&channels, ceilingDBTP: peakCeilingDBFS, sampleRate: sampleRate)
        return lufs
    }
}
