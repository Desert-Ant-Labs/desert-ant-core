// The Kaldi-compatible filterbank frontend, in Swift.
//
// It lives here rather than in the model artifact because an STFT has no Neural
// Engine kernel: putting it in the graph would split the model into CPU and ANE
// segments and cost a transfer at each crossing, for work that is about a
// millisecond here. The Core ML program is 100% ANE-resident precisely because
// this stage stays outside it.
//
// This is a port of kaldi_native_fbank with FireRedVAD's options (25 ms window,
// 10 ms hop, snip_edges, no dither, 80 bins), and it has to match bit-closely:
// the model consumes raw filterbank and folds Kaldi CMVN into its first layer,
// so a frontend that is merely "a log-mel spectrogram" produces confident
// nonsense rather than an error. `Tests/CueTests` pins it against vectors
// generated from the Python implementation.
//
// Two details are easy to miss and both change every number:
//   - samples are at int16 scale (+/-32768), not normalised to +/-1
//   - the mel filterbank spans nFFT/2 bins, dropping the Nyquist bin

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import AudioDSP
import Foundation

struct Frontend: Sendable {
    struct Geometry: Sendable, Codable {
        let sampleRate: Int
        let frameLengthSamples: Int
        let frameShiftSamples: Int
        let nFFT: Int
        let mels: Int
        let melLowHz: Double
        let melHighHz: Double
        let preemphasis: Float
    }

    let geometry: Geometry
    /// Povey window: a Hann raised to 0.85, over `frameLengthSamples`.
    private let window: [Float]
    /// [melBins * mels], row major, i.e. already transposed for the matmul that
    /// applies it. `melBins` is nFFT/2: Kaldi drops the Nyquist bin.
    private let filters: [Float]
    private let melBins: Int
    private let cosTable: [Float]
    private let sinTable: [Float]

    init(geometry g: Geometry) throws {
        guard g.frameLengthSamples > 1, g.frameShiftSamples > 0,
              g.nFFT >= g.frameLengthSamples, g.mels > 0 else {
            throw CueError.invalidModel("frontend geometry is out of range")
        }
        geometry = g
        melBins = g.nFFT / 2

        let n = g.frameLengthSamples
        let a = 2 * Double.pi / Double(n - 1)
        window = (0..<n).map { Float(pow(0.5 - 0.5 * cos(a * Double($0)), 0.85)) }

        filters = Frontend.filterbank(
            sampleRate: Double(g.sampleRate), nFFT: g.nFFT, melBins: g.nFFT / 2,
            mels: g.mels, lowHz: g.melLowHz, highHz: g.melHighHz)

        // Real DFT basis for the zero-padded frame. nFFT is 512 here, so the
        // naive transform is 512 * 256 multiply-adds per frame; at 100 frames a
        // second that is not worth an FFT's index bookkeeping, and `Matmul`
        // routes it through Accelerate on Apple anyway.
        var c = [Float](repeating: 0, count: g.nFFT * melBins)
        var s = [Float](repeating: 0, count: g.nFFT * melBins)
        for t in 0..<g.nFFT {
            for k in 0..<melBins {
                let angle = 2 * Double.pi * Double(k) * Double(t) / Double(g.nFFT)
                c[t * melBins + k] = Float(cos(angle))
                s[t * melBins + k] = Float(sin(angle))
            }
        }
        cosTable = c
        sinTable = s
    }

    /// Kaldi's mel scale: 1127 ln(1 + f/700). Equivalent to the HTK form.
    private static func hzToMel(_ hz: Double) -> Double { 1127.0 * log(1.0 + hz / 700.0) }

    private static func filterbank(sampleRate: Double, nFFT: Int, melBins: Int,
                                   mels: Int, lowHz: Double, highHz: Double) -> [Float] {
        let binWidth = sampleRate / Double(nFFT)
        let melLow = hzToMel(lowHz), melHigh = hzToMel(highHz)
        let delta = (melHigh - melLow) / Double(mels + 1)
        // Stored transposed, [melBins x mels], so applying it is one gemm.
        var fb = [Float](repeating: 0, count: melBins * mels)
        for m in 0..<mels {
            let left = melLow + Double(m) * delta
            let center = melLow + Double(m + 1) * delta
            let right = melLow + Double(m + 2) * delta
            for k in 0..<melBins {
                let mel = hzToMel(binWidth * Double(k))
                guard mel > left, mel < right else { continue }
                let w = mel <= center
                    ? (mel - left) / (center - left)
                    : (right - mel) / (right - center)
                fb[k * mels + m] = Float(w)
            }
        }
        return fb
    }

    /// Frames produced from `samples` under snip_edges: no padding, no centering.
    func frameCount(samples: Int) -> Int {
        samples < geometry.frameLengthSamples
            ? 0
            : (samples - geometry.frameLengthSamples) / geometry.frameShiftSamples + 1
    }

    /// Raw filterbank, frame-major `frames * mels`.
    ///
    /// `samples` must be at int16 scale. `Cue` scales normalised float audio on
    /// the way in; this stays in Kaldi's units so the port is checkable against
    /// the Python line for line.
    func features(_ samples: [Float]) -> (values: [Float], frames: Int) {
        let n = geometry.frameLengthSamples
        let frames = frameCount(samples: samples.count)
        guard frames > 0 else { return ([], 0) }

        let nFFT = geometry.nFFT, mels = geometry.mels
        var padded = [Float](repeating: 0, count: frames * nFFT)
        for f in 0..<frames {
            let off = f * geometry.frameShiftSamples
            let base = f * nFFT
            // remove_dc_offset: Kaldi subtracts the frame mean, not a running one.
            var mean: Float = 0
            for i in 0..<n { mean += samples[off + i] }
            mean /= Float(n)
            for i in 0..<n { padded[base + i] = samples[off + i] - mean }
            // Preemphasis runs backwards so each tap sees the un-emphasised
            // previous sample; the first sample uses itself.
            let p = geometry.preemphasis
            if p != 0 {
                var i = n - 1
                while i >= 1 {
                    padded[base + i] -= p * padded[base + i - 1]
                    i -= 1
                }
                padded[base] -= p * padded[base]
            }
            for i in 0..<n { padded[base + i] *= window[i] }
            // Tail of the frame stays zero out to nFFT.
        }

        var re = [Float](repeating: 0, count: frames * melBins)
        var im = [Float](repeating: 0, count: frames * melBins)
        Matmul.gemm(padded, cosTable, into: &re, m: frames, n: melBins, k: nFFT, alpha: 1)
        Matmul.gemm(padded, sinTable, into: &im, m: frames, n: melBins, k: nFFT, alpha: -1)

        var power = [Float](repeating: 0, count: frames * melBins)
        for i in 0..<power.count { power[i] = re[i] * re[i] + im[i] * im[i] }

        var out = [Float](repeating: 0, count: frames * mels)
        Matmul.gemm(power, filters, into: &out, m: frames, n: mels, k: melBins)
        // Kaldi floors at float epsilon before the log, so a silent frame is a
        // large negative number rather than -infinity.
        for i in 0..<out.count { out[i] = log(max(out[i], Float.ulpOfOne)) }
        return (out, frames)
    }
}
