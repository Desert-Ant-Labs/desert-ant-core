// STFT / ISTFT as exact real-DFT matmuls (so `nFFT` need not be a power of two)
// with windowed COLA overlap-add reconstruction. This is the DSP a spectral
// speech model runs on both sides of inference; one implementation, shared by
// every SDK, matches the training-time `torch.stft`/`istft` (Hann, center,
// reflect pad) it has to agree with bit-for-bit.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(WASILibc)
import WASILibc
#endif

/// A dense complex spectrogram in frame-major layout: `frames` rows of `bins`
/// (= `nFFT/2 + 1`) complex bins, real and imaginary parts split into two
/// parallel `frames * bins` arrays (row `f`, bin `k` at index `f * bins + k`).
public struct Spectrogram: Sendable {
    public var re: [Float]
    public var im: [Float]
    public let frames: Int
    public let bins: Int

    public init(re: [Float], im: [Float], frames: Int, bins: Int) {
        self.re = re
        self.im = im
        self.frames = frames
        self.bins = bins
    }

    /// Per-bin magnitude `sqrt(re^2 + im^2)` (frame-major, `frames * bins`).
    public func magnitude(eps: Float = 0) -> [Float] {
        var out = [Float](repeating: 0, count: re.count)
        for i in 0..<re.count { out[i] = (re[i] * re[i] + im[i] * im[i] + eps).squareRoot() }
        return out
    }

    /// Per-bin phase `atan2(im, re)` (frame-major, `frames * bins`).
    public func phase() -> [Float] {
        var out = [Float](repeating: 0, count: re.count)
        for i in 0..<re.count { out[i] = atan2f(im[i], re[i]) }
        return out
    }
}

/// A short-time Fourier transform configured once and reused. Precomputes the
/// window and the real-DFT bases at init, so `forward`/`inverse` are just the
/// matmuls plus overlap-add.
public struct STFT: Sendable {
    public let nFFT: Int
    public let hop: Int
    public let bins: Int
    public let center: Bool
    public let window: [Float]

    private let fwdCos: [Float]   // [nFFT x bins]
    private let fwdSin: [Float]   // [nFFT x bins]
    private let invCos: [Float]   // [bins x nFFT]
    private let invSin: [Float]   // [bins x nFFT]

    /// Configure an STFT. `window` defaults to a periodic Hann of length
    /// `nFFT`. `center` reflect-pads by `nFFT/2` so frames are centered
    /// (`torch.stft(center=True)`), which `inverse` undoes.
    public init(nFFT: Int, hop: Int, window: [Float]? = nil, center: Bool = true) {
        precondition(nFFT > 0 && hop > 0, "nFFT and hop must be positive")
        self.nFFT = nFFT
        self.hop = hop
        self.bins = nFFT / 2 + 1
        self.center = center
        let w = window ?? Window.hann(nFFT, periodic: true)
        precondition(w.count == nFFT, "window length must equal nFFT")
        self.window = w

        let n = nFFT, f = bins
        var fc = [Float](repeating: 0, count: n * f)
        var fs = [Float](repeating: 0, count: n * f)
        for t in 0..<n {
            for k in 0..<f {
                let a = 2 * Float.pi * Float(k) * Float(t) / Float(n)
                fc[t * f + k] = cosf(a)
                fs[t * f + k] = sinf(a)
            }
        }
        self.fwdCos = fc
        self.fwdSin = fs

        // Real irfft basis (hermitian): x[t] = sum_k a_k/n (re cos - im sin),
        // a_0 = a_{n/2} = 1, else 2.
        var ic = [Float](repeating: 0, count: f * n)
        var isn = [Float](repeating: 0, count: f * n)
        for k in 0..<f {
            let ak: Float = (k == 0 || k == f - 1) ? 1 : 2
            for t in 0..<n {
                let a = 2 * Float.pi * Float(k) * Float(t) / Float(n)
                ic[k * n + t] = ak / Float(n) * cosf(a)
                isn[k * n + t] = -ak / Float(n) * sinf(a)
            }
        }
        self.invCos = ic
        self.invSin = isn
    }

    /// Forward transform: windowed frames -> complex spectrogram.
    public func forward(_ signal: [Float]) -> Spectrogram {
        let n = nFFT, f = bins
        let padded = center ? Padding.reflect(signal, pad: n / 2) : signal
        guard padded.count >= n else { return Spectrogram(re: [], im: [], frames: 0, bins: f) }
        let frames = 1 + (padded.count - n) / hop

        var windowed = [Float](repeating: 0, count: frames * n)
        for fr in 0..<frames {
            let off = fr * hop
            for t in 0..<n { windowed[fr * n + t] = padded[off + t] * window[t] }
        }
        var re = [Float](repeating: 0, count: frames * f)
        var im = [Float](repeating: 0, count: frames * f)
        Matmul.gemm(windowed, fwdCos, into: &re, m: frames, n: f, k: n, alpha: 1)
        Matmul.gemm(windowed, fwdSin, into: &im, m: frames, n: f, k: n, alpha: -1)
        return Spectrogram(re: re, im: im, frames: frames, bins: f)
    }

    /// Inverse transform: complex spectrogram -> signal, windowed COLA
    /// overlap-add with the same window, trimming the centered padding and
    /// clamping to `length` (pass the original sample count).
    public func inverse(_ spec: Spectrogram, length: Int) -> [Float] {
        let n = nFFT, f = bins, frames = spec.frames
        guard frames > 0 else { return [] }
        var recon = [Float](repeating: 0, count: frames * n)
        Matmul.gemm(spec.re, invCos, into: &recon, m: frames, n: n, k: f, alpha: 1)
        Matmul.gemm(spec.im, invSin, into: &recon, m: frames, n: n, k: f, alpha: 1, beta: 1)

        let paddedLen = (frames - 1) * hop + n
        var num = [Float](repeating: 0, count: paddedLen)
        var den = [Float](repeating: 0, count: paddedLen)
        for fr in 0..<frames {
            let off = fr * hop
            for t in 0..<n {
                let w = window[t]
                num[off + t] += recon[fr * n + t] * w
                den[off + t] += w * w
            }
        }
        var y = [Float](repeating: 0, count: paddedLen)
        for i in 0..<paddedLen { y[i] = den[i] > 1e-8 ? num[i] / den[i] : 0 }

        let pad = center ? n / 2 : 0
        let count = min(length, paddedLen - 2 * pad)
        return count > 0 ? Array(y[pad..<(pad + count)]) : []
    }
}
