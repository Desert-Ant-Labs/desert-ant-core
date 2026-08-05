// Log-mel spectrogram front-end for audio feature models (ASR-adjacent nets,
// keyword/filler detectors that take mel rather than raw waveform). Builds the
// triangular mel filterbank once, applies it to STFT power, and takes the log.
// HTK mel scale by default, matching whisper/torchaudio's common setting.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(WASILibc)
import WASILibc
#endif

/// A triangular mel filterbank plus the STFT that feeds it. Configured once and
/// reused: `logMel(_:)` takes a signal to a `[mels x frames]`-ordered log-mel
/// spectrogram (frame-major internally, exposed as `frames * mels`).
public struct MelSpectrogram: Sendable {
    public let stft: STFT
    public let mels: Int
    public let sampleRate: Double
    private let filters: [Float]   // [mels x bins]
    private let bins: Int

    /// Configure a mel front-end. `fMax` defaults to Nyquist (`sampleRate/2`).
    public init(sampleRate: Double, nFFT: Int, hop: Int, mels: Int,
                fMin: Double = 0, fMax: Double? = nil, htk: Bool = true,
                window: [Float]? = nil, center: Bool = true) {
        self.stft = STFT(nFFT: nFFT, hop: hop, window: window, center: center)
        self.mels = mels
        self.sampleRate = sampleRate
        self.bins = stft.bins
        self.filters = MelSpectrogram.filterbank(
            sampleRate: sampleRate, nFFT: nFFT, bins: stft.bins,
            mels: mels, fMin: fMin, fMax: fMax ?? sampleRate / 2, htk: htk)
    }

    private static func hzToMel(_ hz: Double, htk: Bool) -> Double {
        htk ? 2595 * log10(1 + hz / 700) : hz  // HTK; linear placeholder only if !htk unused
    }
    private static func melToHz(_ mel: Double, htk: Bool) -> Double {
        htk ? 700 * (pow(10, mel / 2595) - 1) : mel
    }

    private static func filterbank(sampleRate: Double, nFFT: Int, bins: Int,
                                   mels: Int, fMin: Double, fMax: Double, htk: Bool) -> [Float] {
        let melMin = hzToMel(fMin, htk: htk), melMax = hzToMel(fMax, htk: htk)
        // mels + 2 band edges, evenly spaced on the mel scale.
        var hzPoints = [Double](repeating: 0, count: mels + 2)
        for i in 0..<(mels + 2) {
            let mel = melMin + (melMax - melMin) * Double(i) / Double(mels + 1)
            hzPoints[i] = melToHz(mel, htk: htk)
        }
        // FFT bin center frequencies.
        var binHz = [Double](repeating: 0, count: bins)
        for k in 0..<bins { binHz[k] = Double(k) * sampleRate / Double(nFFT) }

        var fb = [Float](repeating: 0, count: mels * bins)
        for m in 0..<mels {
            let left = hzPoints[m], center = hzPoints[m + 1], right = hzPoints[m + 2]
            for k in 0..<bins {
                let hz = binHz[k]
                var w = 0.0
                if hz >= left, hz <= center, center > left {
                    w = (hz - left) / (center - left)
                } else if hz > center, hz <= right, right > center {
                    w = (right - hz) / (right - center)
                }
                fb[m * bins + k] = Float(max(0, w))
            }
        }
        return fb
    }

    /// Log-mel spectrogram of `signal`, frame-major `frames * mels`. `log` is
    /// natural log of `power + eps` (set `power: false` for magnitude).
    public func logMel(_ signal: [Float], eps: Float = 1e-10, power: Bool = true) -> (values: [Float], frames: Int, mels: Int) {
        let spec = stft.forward(signal)
        let frames = spec.frames
        guard frames > 0 else { return ([], 0, mels) }
        // Per-bin magnitude/power, frame-major [frames x bins].
        var energy = [Float](repeating: 0, count: frames * bins)
        for i in 0..<energy.count {
            let mag2 = spec.re[i] * spec.re[i] + spec.im[i] * spec.im[i]
            energy[i] = power ? mag2 : mag2.squareRoot()
        }
        // mel[frames x mels] = energy[frames x bins] @ filters^T[bins x mels].
        var out = [Float](repeating: 0, count: frames * mels)
        for fr in 0..<frames {
            for m in 0..<mels {
                var acc: Float = 0
                let eRow = fr * bins, fRow = m * bins
                for k in 0..<bins { acc += energy[eRow + k] * filters[fRow + k] }
                out[fr * mels + m] = logf(acc + eps)
            }
        }
        return (out, frames, mels)
    }
}
