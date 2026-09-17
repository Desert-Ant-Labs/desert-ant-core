import AudioDSP
import RealModule

/// n_fft 512, a 400-sample periodic Hann centered in the frame, hop 160, reflect padding, 40 mel bins, log(mel + eps), whole-utterance then per-crop normalization.
struct Frontend: Sendable {
    let cfg: RefinerConfig
    private let melFilters: [Float]
    private let stft: STFT

    init(cfg: RefinerConfig, melFilters: [Float]) {
        self.cfg = cfg
        self.melFilters = melFilters
        var window = [Float](repeating: 0, count: cfg.n_fft)
        let hann = Window.hann(cfg.win_length, periodic: true)
        let left = (cfg.n_fft - cfg.win_length) / 2
        for n in 0..<cfg.win_length { window[left + n] = hann[n] }
        self.stft = STFT(nFFT: cfg.n_fft, hop: cfg.hop_length, window: window, center: true)
    }

    func logMel(_ samples: [Float]) -> (data: [Float], nFrames: Int) {
        let spec = stft.forward(samples)
        let bins = spec.bins, nFrames = spec.frames, nmels = cfg.n_mels
        var out = [Float](repeating: 0, count: nmels * nFrames)
        for t in 0..<nFrames {
            let row = t * bins
            for m in 0..<nmels {
                var acc: Float = 0
                let base = m * bins
                for k in 0..<bins {
                    let re = spec.re[row + k], im = spec.im[row + k]
                    acc += melFilters[base + k] * (re * re + im * im)
                }
                out[m * nFrames + t] = Float.log(acc + cfg.log_eps)
            }
        }
        normalize(&out)
        return (out, nFrames)
    }

    func crop(_ logmel: [Float], nFrames: Int, centerFrame: Int, width: Int) -> [Float] {
        let nmels = cfg.n_mels, half = width / 2
        var out = [Float](repeating: 0, count: nmels * width)
        for m in 0..<nmels {
            for j in 0..<width {
                var src = centerFrame - half + j
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
        let n = Float(x.count)
        var mean: Float = 0
        for v in x { mean += v }
        mean /= n
        var sq: Float = 0
        for i in 0..<x.count { x[i] -= mean; sq += x[i] * x[i] }
        let std = (sq / n).squareRoot()
        let inv: Float = std > 1e-8 ? 1 / std : 1e8
        for i in 0..<x.count { x[i] *= inv }
    }

    func timeToFrame(_ t: Double) -> Int { Int((t * Double(cfg.sample_rate) / Double(cfg.hop_length)).rounded()) }
}
