import Accelerate
import Foundation

/// Log-mel frontend matching the Python contract (docs/frontend.md in align-training).
/// n_fft 512, 400-sample Hann centered in the FFT, hop 160, 40 Slaney mel bins,
/// log(mel + eps), reflect padding, whole-utterance then per-crop normalization.
///
/// Absolute FFT scaling is irrelevant here: mel is linear in power and we take log then
/// zero-mean/unit-std normalize, so any constant power scale becomes an additive constant
/// that normalization removes. Only the window shape, mel filterbank, log, and framing matter.
final class Frontend {
    let cfg: RefinerConfig
    private let melFilters: [Float]      // [n_mels * n_fft_bins], row-major
    private let window: [Float]          // [n_fft], Hann(400) centered
    private let log2n: vDSP_Length
    private let fftSetupZrip: FFTSetup

    init(cfg: RefinerConfig, melFilters: [Float]) {
        self.cfg = cfg
        self.melFilters = melFilters
        // Hann window of win_length, centered inside n_fft (zeros on both sides).
        var win = [Float](repeating: 0, count: cfg.n_fft)
        let w = cfg.win_length
        var hann = [Float](repeating: 0, count: w)
        // numpy hanning(w+1)[:-1]: 0.5 - 0.5*cos(2*pi*n/w)
        for n in 0..<w { hann[n] = 0.5 - 0.5 * cos(2.0 * .pi * Float(n) / Float(w)) }
        let left = (cfg.n_fft - w) / 2
        for n in 0..<w { win[left + n] = hann[n] }
        self.window = win
        self.log2n = vDSP_Length(Int(log2(Double(cfg.n_fft))))
        self.fftSetupZrip = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetup(fftSetupZrip) }

    /// Whole-utterance log-mel, returned as [n_mels * nFrames] row-major (mel-major),
    /// already zero-mean/unit-std normalized over the whole array.
    func logMel(_ samples: [Float]) -> (data: [Float], nFrames: Int) {
        let nfft = cfg.n_fft, hop = cfg.hop_length, pad = cfg.n_fft / 2
        let bins = cfg.n_fft_bins, nmels = cfg.n_mels

        // reflect pad
        var padded = [Float](repeating: 0, count: samples.count + 2 * pad)
        for i in 0..<pad { padded[i] = samples[min(pad - i, samples.count - 1)] }         // reflect left
        for i in 0..<samples.count { padded[pad + i] = samples[i] }
        for i in 0..<pad { padded[pad + samples.count + i] = samples[max(samples.count - 2 - i, 0)] }

        let nFrames = 1 + (padded.count - nfft) / hop
        var out = [Float](repeating: 0, count: nmels * nFrames)

        var realp = [Float](repeating: 0, count: nfft / 2)
        var imagp = [Float](repeating: 0, count: nfft / 2)
        var frame = [Float](repeating: 0, count: nfft)
        var power = [Float](repeating: 0, count: bins)

        for t in 0..<nFrames {
            let start = t * hop
            // windowed frame
            vDSP_vmul(Array(padded[start..<start + nfft]), 1, window, 1, &frame, 1, vDSP_Length(nfft))
            // real FFT via zrip (in-place split-complex packing)
            realp.withUnsafeMutableBufferPointer { rp in
                imagp.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBytes { raw in
                        let cptr = raw.bindMemory(to: DSPComplex.self)
                        vDSP_ctoz(cptr.baseAddress!, 2, &split, 1, vDSP_Length(nfft / 2))
                    }
                    vDSP_fft_zrip(fftSetupZrip, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    // power spectrum: bin 0 = DC (realp[0]), Nyquist packed in imagp[0]
                    power[0] = split.realp[0] * split.realp[0]
                    power[bins - 1] = split.imagp[0] * split.imagp[0]
                    for k in 1..<(nfft / 2) {
                        power[k] = split.realp[k] * split.realp[k] + split.imagp[k] * split.imagp[k]
                    }
                }
            }
            // mel = filterbank @ power ; log(mel + eps)
            for m in 0..<nmels {
                var acc: Float = 0
                let base = m * bins
                vDSP_dotpr(melFilters[base..<base + bins].withUnsafeBufferPointer { $0.baseAddress! },
                           1, power, 1, &acc, vDSP_Length(bins))
                out[m * nFrames + t] = log(acc + cfg.log_eps)
            }
        }
        normalize(&out)
        return (out, nFrames)
    }

    /// Extract a fixed-width crop [n_mels * width] centered at `centerFrame`, reflect-padded
    /// and per-crop normalized. Returns row-major mel-major (matches Core ML [1,40,width]).
    func crop(_ logmel: [Float], nFrames: Int, centerFrame: Int, width: Int) -> [Float] {
        let nmels = cfg.n_mels
        let half = width / 2
        var out = [Float](repeating: 0, count: nmels * width)
        for m in 0..<nmels {
            for j in 0..<width {
                var src = centerFrame - half + j
                // reflect at edges
                if src < 0 { src = -src }
                if src >= nFrames { src = 2 * (nFrames - 1) - src }
                src = max(0, min(nFrames - 1, src))
                out[m * width + j] = logmel[m * nFrames + src]
            }
        }
        normalize(&out)
        return out
    }

    private func normalize(_ x: inout [Float]) {
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(x.count))
        var negMean = -mean
        vDSP_vsadd(x, 1, &negMean, &x, 1, vDSP_Length(x.count))
        var std: Float = 0
        vDSP_rmsqv(x, 1, &std, vDSP_Length(x.count))  // rms of zero-mean = std
        var inv = std > 1e-8 ? 1.0 / std : 1e8
        vDSP_vsmul(x, 1, &inv, &x, 1, vDSP_Length(x.count))
    }

    func timeToFrame(_ t: Double) -> Int { Int((t * Double(cfg.sample_rate) / Double(cfg.hop_length)).rounded()) }
}
