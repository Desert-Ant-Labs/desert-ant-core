import Testing
import Foundation
@testable import AudioDSP

struct FFTTests {
    // Deterministic uniform noise in [-1, 1).
    private struct LCG {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(state >> 11) / Double(1 << 53)) * 2 - 1
        }
    }

    private func noise(_ n: Int, seed: UInt64, amplitude: Float = 0.5) -> [Float] {
        var g = LCG(state: seed)
        return (0..<n).map { _ in g.next() * amplitude }
    }

    // Voiced harmonics under a syllable-rate envelope, with silent gaps and a noise floor.
    private func speechLike(_ n: Int, sr: Double = 16000) -> [Float] {
        var g = LCG(state: 11)
        return (0..<n).map { i in
            let t = Double(i) / sr
            let f0 = 120 + 30 * sin(2 * .pi * 0.7 * t)
            var v = 0.0
            for h in 1...12 { v += sin(2 * .pi * f0 * Double(h) * t) / Double(h) }
            let envelope = max(0, sin(2 * .pi * 4 * t))
            let gate = (Int(t * 2) % 5 == 4) ? 0.0 : 1.0
            return Float(0.2 * v * envelope * gate) + g.next() * 1e-4
        }
    }

    // The align frontend's window: a 400-sample periodic Hann centered in 512.
    private func centeredHann(nFFT: Int = 512, length: Int = 400) -> [Float] {
        var w = [Float](repeating: 0, count: nFFT)
        let hann = Window.hann(length, periodic: true)
        for i in 0..<length { w[(nFFT - length) / 2 + i] = hann[i] }
        return w
    }

    // Double-precision real DFT of one frame, bins 0...n/2.
    private func referenceDFT(_ x: [Float]) -> (re: [Double], im: [Double]) {
        let n = x.count, bins = n / 2 + 1
        var re = [Double](repeating: 0, count: bins), im = re
        for k in 0..<bins {
            for t in 0..<n {
                let a = 2 * Double.pi * Double((k * t) % n) / Double(n)
                re[k] += Double(x[t]) * cos(a)
                im[k] -= Double(x[t]) * sin(a)
            }
        }
        return (re, im)
    }

    @Test(arguments: [4, 8, 16, 64, 256, 512, 1024])
    func realFFTMatchesDoubleDFT(_ n: Int) throws {
        let fft = try #require(RealFFT(n: n))
        let x = noise(n, seed: UInt64(n))
        let ones = [Float](repeating: 1, count: n)
        var re = [Float](repeating: 0, count: n / 2 + 1), im = re
        var zr = [Float](repeating: 0, count: n / 2), zi = zr
        fft.forward(x, window: ones, outRe: &re, outIm: &im, zr: &zr, zi: &zi)
        let ref = referenceDFT(x)
        var err = 0.0, peak = 0.0
        for k in 0...(n / 2) {
            err = max(err, abs(Double(re[k]) - ref.re[k]), abs(Double(im[k]) - ref.im[k]))
            peak = max(peak, hypot(ref.re[k], ref.im[k]))
        }
        // Float32 FFT error grows like log2(n) ulps of the peak bin.
        #expect(err / peak < 1e-6, "n \(n): relative error \(err / peak)")
    }

    @Test func realFFTRejectsNonPowerOfTwo() {
        #expect(RealFFT(n: 400) == nil)
        #expect(RealFFT(n: 2) == nil)
        #expect(STFT(nFFT: 400, hop: 160).hasFFT == false)
        #expect(STFT(nFFT: 512, hop: 160).hasFFT)
    }

    @Test(arguments: ["noise", "speech", "quiet", "tones"])
    func stftFFTMatchesMatmul(_ kind: String) {
        let n = 16000 * 3
        let signal: [Float]
        switch kind {
        case "noise": signal = noise(n, seed: 3)
        case "speech": signal = speechLike(n)
        case "quiet": signal = noise(n, seed: 5, amplitude: 1e-4)
        default: signal = (0..<n).map { i -> Float in
            let t = Double(i) / 16000
            let v: Double = 0.3 * sin(2 * .pi * 440 * t) + 0.1 * sin(2 * .pi * 3001 * t)
            return Float(v)
        }
        }
        let stft = STFT(nFFT: 512, hop: 160, window: centeredHann())
        let a = stft.forwardFFT(signal), b = stft.forwardMatmul(signal)
        #expect(a.frames == b.frames && a.bins == b.bins)
        let e = errors(stft, signal, a, b)
        print("stft \(kind): fft-vs-matmul \(e.diff), fft-vs-double \(e.fft), matmul-vs-double \(e.matmul)")
        // The matmul bases take cosf of angles up to ~1600 rad, so its own error reaches ~6e-5 of peak.
        #expect(e.fft < 1e-6)
        #expect(e.fft <= e.matmul)
        #expect(e.diff < 2e-4)
    }

    @Test func stftFFTHandlesShortAndUncenteredInput() {
        let stft = STFT(nFFT: 512, hop: 160, center: false)
        #expect(stft.forwardFFT(noise(100, seed: 1)).frames == 0)
        let x = noise(2000, seed: 2)
        let a = stft.forwardFFT(x), b = stft.forwardMatmul(x)
        #expect(a.frames == b.frames && a.frames == 1 + (2000 - 512) / 160)
        let e = errors(stft, x, a, b)
        #expect(e.fft < 1e-6)
        #expect(e.diff < 2e-4)
    }

    // Max abs errors relative to the peak bin: FFT vs matmul, and each vs a Double DFT on sampled frames.
    private func errors(_ stft: STFT, _ signal: [Float], _ a: Spectrogram, _ b: Spectrogram)
        -> (diff: Double, fft: Double, matmul: Double) {
        let n = stft.nFFT, f = stft.bins
        let padded = stft.center ? Padding.reflect(signal, pad: n / 2) : signal
        var diff = 0.0, errA = 0.0, errB = 0.0, peak = 0.0
        for i in 0..<a.re.count {
            diff = max(diff, Double(abs(a.re[i] - b.re[i])), Double(abs(a.im[i] - b.im[i])))
        }
        for fr in stride(from: 0, to: a.frames, by: max(1, a.frames / 24)) {
            let frame = (0..<n).map { padded[fr * stft.hop + $0] * stft.window[$0] }
            let ref = referenceDFT(frame)
            for k in 0..<f {
                let i = fr * f + k
                peak = max(peak, hypot(ref.re[k], ref.im[k]))
                errA = max(errA, abs(Double(a.re[i]) - ref.re[k]), abs(Double(a.im[i]) - ref.im[k]))
                errB = max(errB, abs(Double(b.re[i]) - ref.re[k]), abs(Double(b.im[i]) - ref.im[k]))
            }
        }
        var fullPeak = 0.0
        for i in 0..<b.re.count { fullPeak = max(fullPeak, Double(abs(b.re[i])), Double(abs(b.im[i]))) }
        return (diff / fullPeak, errA / peak, errB / peak)
    }

    @Test func forwardDispatchesByPlatformAndSize() {
        let x = noise(4000, seed: 9)
        let pow2 = STFT(nFFT: 256, hop: 64), odd = STFT(nFFT: 400, hop: 100)
        #if canImport(Accelerate)
        #expect(pow2.forward(x).re == pow2.forwardMatmul(x).re)
        #else
        #expect(pow2.forward(x).re == pow2.forwardFFT(x).re)
        #endif
        #expect(odd.forward(x).re == odd.forwardMatmul(x).re)
    }

    @Test func portableGemmMatchesTripleLoopExactly() {
        let m = 7, n = 33, k = 19
        let a = noise(m * k, seed: 21), b = noise(k * n, seed: 22)
        for (alpha, beta) in [(Float(1), Float(0)), (0.5, 0), (1, 1), (2, -0.25)] {
            var c = noise(m * n, seed: 23), expected = c
            for i in 0..<m {
                for j in 0..<n {
                    var acc: Float = 0
                    for p in 0..<k { acc += a[i * k + p] * b[p * n + j] }
                    expected[i * n + j] = alpha * acc + beta * expected[i * n + j]
                }
            }
            Matmul.gemmPortable(a, b, into: &c, m: m, n: n, k: k, alpha: alpha, beta: beta)
            #expect(c == expected, "alpha \(alpha) beta \(beta)")
        }
        var empty: [Float] = [1, 2]
        Matmul.gemmPortable([], [], into: &empty, m: 1, n: 2, k: 0, alpha: 1, beta: 1)
        #expect(empty == [1, 2])
    }
}
