// Look-ahead peak limiting and true-peak measurement: the half of mastering
// that rides transients instead of turning the whole file down.
//
// A single static gain cannot hold a loudness target and a peak ceiling at the
// same time: one transient above the ceiling forces the gain down for the
// entire signal, landing the master below the LUFS it was asked for. The
// limiter pulls gain down only around the peaks that need it, so a delivery
// spec like -16 LUFS at -1.5 dBTP is met rather than approximated.
//
// Attack is instantaneous - the look-ahead window is what buys the time to
// reach the required gain before the peak arrives - and release is exponential.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(WASILibc)
import WASILibc
#endif

public enum Limiter {
    /// How far ahead the limiter sees. The gain is already at its target when
    /// the peak arrives, so the attack costs no distortion.
    public static let lookaheadSeconds = 0.005
    /// Exponential release back to unity gain once a peak has passed.
    public static let releaseSeconds = 0.050

    /// True peak in dBFS across every channel, by 4x linear interpolation, or
    /// `-infinity` for digital silence.
    ///
    /// Inter-sample peaks live between samples, so the largest sample is not
    /// the largest value a DAC will reconstruct. Four phases is the BS.1770
    /// oversampling factor; linear interpolation is the approximation the
    /// platform SDKs shipped, and it errs low by a fraction of a dB rather
    /// than reporting a peak that is not there.
    public static func truePeakDBFS(_ channels: [[Float]]) -> Double {
        var maxAbs: Float = 0
        for channel in channels {
            var prev: Float = 0
            for cur in channel {
                maxAbs = max(maxAbs, abs(cur))
                maxAbs = max(maxAbs, abs(0.75 * prev + 0.25 * cur))
                maxAbs = max(maxAbs, abs(0.50 * prev + 0.50 * cur))
                maxAbs = max(maxAbs, abs(0.25 * prev + 0.75 * cur))
                prev = cur
            }
        }
        guard maxAbs > 0 else { return -.infinity }
        return 20 * log10(Double(maxAbs))
    }

    /// Limit `channels` in place so nothing exceeds `ceilingDBTP`.
    ///
    /// Implemented as one pass of ``Limiter/Streaming`` over the whole signal
    /// rather than as its own loop, so the in-memory and file-streaming paths
    /// cannot drift apart.
    public static func apply(_ channels: inout [[Float]], ceilingDBTP: Double, sampleRate: Double) {
        guard !channels.isEmpty, (channels.first?.count ?? 0) > 0 else { return }
        let limiter = Streaming(ceilingDBTP: ceilingDBTP, sampleRate: sampleRate,
                                channels: channels.count)
        var out = limiter.process(channels)
        let tail = limiter.flush()
        for c in 0..<out.count { out[c].append(contentsOf: tail[c]) }
        channels = out
    }

    /// Per-position magnitude across channels: what the envelope reacts to.
    static func jointMagnitude(_ channels: [[Float]], count n: Int) -> [Float] {
        var absX = [Float](repeating: 0, count: n)
        for channel in channels {
            channel.withUnsafeBufferPointer { src in
                guard let p = src.baseAddress else { return }
                for i in 0..<n {
                    let a = abs(p[i])
                    if a > absX[i] { absX[i] = a }
                }
            }
        }
        return absX
    }

    /// A limiter over a signal delivered in pieces.
    ///
    /// `process` can only emit samples whose look-ahead window it has actually
    /// seen, so it holds the last `lookahead` samples of every chunk back and
    /// returns them from a later `process` or from `flush`. Feeding the whole
    /// signal in one call and then flushing gives the same samples as feeding
    /// it in pieces: the envelope and the held-back tail both carry across.
    ///
    /// Not thread safe; feed it from one place.
    public final class Streaming {
        private let ceiling: Float
        private let lookahead: Int
        private let release: Float
        /// The gain envelope, carried across calls. This is the state that
        /// makes chunked limiting identical to whole-signal limiting.
        private var env: Float = 1
        private var pending: [[Float]]

        public init(ceilingDBTP: Double, sampleRate: Double, channels: Int) {
            ceiling = Float(pow(10, ceilingDBTP / 20))
            lookahead = max(0, Int(Limiter.lookaheadSeconds * sampleRate))
            release = Float(exp(-1.0 / (sampleRate * Limiter.releaseSeconds)))
            pending = Array(repeating: [], count: max(0, channels))
        }

        /// Limit what can be finished, and hold the rest for the next call.
        public func process(_ chunk: [[Float]]) -> [[Float]] {
            let nCh = pending.count
            guard chunk.count == nCh, nCh > 0 else { return chunk }
            var joined = [[Float]]()
            joined.reserveCapacity(nCh)
            for c in 0..<nCh { joined.append(pending[c] + chunk[c]) }

            let total = joined[0].count
            guard total > 0 else { return Array(repeating: [], count: nCh) }
            let finishable = max(0, total - lookahead)
            let out = run(joined, count: finishable, horizon: total)
            for c in 0..<nCh { pending[c] = Array(joined[c][finishable...]) }
            return out
        }

        /// Emit the held-back tail. Past the end of the signal there is nothing
        /// left to look ahead at, so the window simply shrinks.
        public func flush() -> [[Float]] {
            let nCh = pending.count
            let n = pending.first?.count ?? 0
            guard n > 0 else { return Array(repeating: [], count: nCh) }
            let out = run(pending, count: n, horizon: n)
            for c in 0..<nCh { pending[c] = [] }
            return out
        }

        /// Apply the envelope to the first `count` samples, reacting to peaks
        /// up to `horizon`.
        ///
        /// The window maximum comes from a monotonic-decreasing deque, which is
        /// O(n) overall rather than O(n * lookahead). Its ring buffer holds
        /// `lookahead + 2` slots because that is all that can be live at once -
        /// sizing it to the signal cost ~115 MB on a five-minute stereo file.
        private func run(_ buf: [[Float]], count: Int, horizon: Int) -> [[Float]] {
            let nCh = buf.count
            let absX = Limiter.jointMagnitude(buf, count: horizon)
            let capacity = max(2, lookahead + 2)
            var dq = [Int](repeating: 0, count: capacity)
            var head = 0, tail = 0

            func push(_ index: Int) {
                let v = absX[index]
                while tail > head, absX[dq[(tail - 1) % capacity]] <= v { tail -= 1 }
                dq[tail % capacity] = index
                tail += 1
            }
            for j in 0..<min(lookahead, horizon) { push(j) }

            var out = (0..<nCh).map { _ in [Float](repeating: 0, count: count) }
            for i in 0..<count {
                let end = i + lookahead
                if end >= lookahead, end < horizon { push(end) }
                while tail > head, dq[head % capacity] < i { head += 1 }
                let ahead = tail > head ? absX[dq[head % capacity]] : 0
                if ahead > ceiling {
                    let required = ceiling / ahead
                    if required < env { env = required }
                }
                for c in 0..<nCh { out[c][i] = buf[c][i] * env }
                env = 1 - (1 - env) * release
            }
            return out
        }
    }
}
