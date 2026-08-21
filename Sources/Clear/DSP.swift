// DeepFilterNet3 DSP: STFT/ISTFT and the ERB + unit-norm feature front-end,
// ported from the (Apple-only) clear-swift reference to portable Swift so it
// runs identically on every platform. Accelerate-backed on Apple, plain loops
// elsewhere; the constants and normalization state-init ramps must match the
// training-time libDF exactly or the model gets out-of-distribution input.

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
#if canImport(Foundation) && !os(Android) && !os(WASI)
import Foundation
#endif
#if canImport(Dispatch)
import Dispatch
#endif
#if canImport(Accelerate)
import Accelerate
#endif

// Carries non-Sendable state (pointers, the FFT pool) into a concurrentPerform
// closure. Safe here: each worker touches a disjoint frame range.
struct Unchecked<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

enum ClearDSP {
    static let fftSize = 960
    static let hopSize = 480
    static let nFreq = 481          // fftSize/2 + 1
    static let nErb = 32
    static let nDf = 96
    static let convLookahead = 2
    static let sampleRate = 48_000.0
    static let normAlpha: Float = 0.99   // round(exp(-hop/sr/tau), 3), tau=1s

    // ERB band widths (bins per band), fixed at training time; sum == nFreq.
    static let erbWidths: [Int] = [
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        5, 5, 7, 7, 8, 10, 12, 13, 15, 18, 20,
        24, 28, 31, 37, 42, 50, 56, 67,
    ]
}

// Row-major single-precision matmul: Accelerate BLAS on Apple, a plain loop
// elsewhere. `c[m x n] = a[m x k] @ b[k x n]`.
enum Gemm {
    static func mul(_ a: [Float], _ b: [Float], into c: inout [Float], m: Int, n: Int, k: Int) {
        #if canImport(Accelerate)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                    Int32(m), Int32(n), Int32(k), 1, a, Int32(k), b, Int32(n), 0, &c, Int32(n))
        #else
        for i in 0..<m {
            let ar = i * k, cr = i * n
            for j in 0..<n { c[cr + j] = 0 }
            for p in 0..<k {
                let av = a[ar + p]
                if av == 0 { continue }
                let br = p * n
                for j in 0..<n { c[cr + j] += av * b[br + j] }
            }
        }
        #endif
    }
}

#if !canImport(Accelerate)
// Portable radix-2 complex FFT (Apple uses vDSP instead). Iterative
// decimation-in-time with precomputed twiddles + bit-reversal.
final class Radix2FFT {
    let n: Int
    private let cosT: [Float], sinT: [Float]   // size n/2
    private let rev: [Int]
    init(n: Int) {
        self.n = n
        var c = [Float](repeating: 0, count: n / 2), s = [Float](repeating: 0, count: n / 2)
        for k in 0..<n / 2 { let a = 2 * Float.pi * Float(k) / Float(n); c[k] = cosf(a); s[k] = sinf(a) }
        cosT = c; sinT = s
        let bits = Int(log2(Double(n)).rounded())
        var r = [Int](repeating: 0, count: n)
        for i in 0..<n { var x = i, y = 0; for _ in 0..<bits { y = (y << 1) | (x & 1); x >>= 1 }; r[i] = y }
        rev = r
    }
    // Pointer-based hot loop: class-member array subscripts carry ARC +
    // exclusivity overhead that dominates otherwise.
    func transform(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>, inverse: Bool) {
        let nn = n
        rev.withUnsafeBufferPointer { rp in
            for i in 0..<nn { let j = rp[i]; if i < j { let a = re[i]; re[i] = re[j]; re[j] = a; let b = im[i]; im[i] = im[j]; im[j] = b } }
        }
        cosT.withUnsafeBufferPointer { cp in sinT.withUnsafeBufferPointer { sp in
            var len = 2
            while len <= nn {
                let half = len >> 1, step = nn / len
                var i = 0
                while i < nn {
                    var k = 0
                    for j in 0..<half {
                        let c = cp[k], s = inverse ? sp[k] : -sp[k]
                        let a = i + j, b = a + half
                        let tr = re[b] * c - im[b] * s, ti = re[b] * s + im[b] * c
                        re[b] = re[a] - tr; im[b] = im[a] - ti
                        re[a] += tr;        im[a] += ti
                        k += step
                    }
                    i += len
                }
                len <<= 1
            }
        } }
        if inverse { let s = 1 / Float(nn); for i in 0..<nn { re[i] *= s; im[i] *= s } }
    }
}

// Mixed-radix 960-point complex FFT via a six-step Cooley-Tukey split
// N = N1*N2 = 64*15: 15 radix-2 FFTs of 64, twiddles, then 64 direct 15-point
// DFTs. ~4x less work than Bluestein (which pads 960 -> 2048 and runs two FFTs
// per transform), which is the portable STFT's dominant cost. Pointer-based
// hot loop; `outR`/`outI` hold the unscaled forward DFT.
final class MixedFFT960 {
    private let n1 = 64, n2 = 15
    private let fft64: Radix2FFT
    private let w15c: [Float], w15s: [Float]   // 15x15 DFT basis (sign -)
    private let twC: [Float], twS: [Float]     // W_960^{n2*k1} (sign -), [15*64]
    private var ar: [Float], ai: [Float]       // input [960]
    private var Br: [Float], Bi: [Float]       // step1+2 result [15*64]
    private var colR: [Float], colI: [Float]   // 64-pt column scratch
    private(set) var outR: [Float], outI: [Float]

    init() {
        fft64 = Radix2FFT(n: 64)
        var c = [Float](repeating: 0, count: 225), s = [Float](repeating: 0, count: 225)
        for a in 0..<15 { for b in 0..<15 { let t = -2 * Float.pi * Float(a * b) / 15; c[a * 15 + b] = cosf(t); s[a * 15 + b] = sinf(t) } }
        w15c = c; w15s = s
        var tc = [Float](repeating: 0, count: 960), ts = [Float](repeating: 0, count: 960)
        for x in 0..<15 { for y in 0..<64 { let t = -2 * Float.pi * Float(x * y) / 960; tc[x * 64 + y] = cosf(t); ts[x * 64 + y] = sinf(t) } }
        twC = tc; twS = ts
        ar = [Float](repeating: 0, count: 960); ai = [Float](repeating: 0, count: 960)
        Br = [Float](repeating: 0, count: 960); Bi = [Float](repeating: 0, count: 960)
        colR = [Float](repeating: 0, count: 64); colI = [Float](repeating: 0, count: 64)
        outR = [Float](repeating: 0, count: 960); outI = [Float](repeating: 0, count: 960)
    }

    private func run() {
        ar.withUnsafeBufferPointer { arp in ai.withUnsafeBufferPointer { aip in
        Br.withUnsafeMutableBufferPointer { brp in Bi.withUnsafeMutableBufferPointer { bip in
        twC.withUnsafeBufferPointer { tcp in twS.withUnsafeBufferPointer { tsp in
            colR.withUnsafeMutableBufferPointer { crp in colI.withUnsafeMutableBufferPointer { cip in
                let cr = crp.baseAddress!, ci = cip.baseAddress!
                for v in 0..<15 {                      // step 1+2, per n2 column
                    for u in 0..<64 { cr[u] = arp[15 * u + v]; ci[u] = aip[15 * u + v] }
                    fft64.transform(cr, ci, inverse: false)
                    for k1 in 0..<64 {
                        let tw = v * 64 + k1, re = cr[k1], im = ci[k1], c = tcp[tw], s = tsp[tw]
                        brp[v * 64 + k1] = re * c - im * s
                        bip[v * 64 + k1] = re * s + im * c
                    }
                }
            } }
            w15c.withUnsafeBufferPointer { wc in w15s.withUnsafeBufferPointer { ws in
            outR.withUnsafeMutableBufferPointer { orp in outI.withUnsafeMutableBufferPointer { oip in
                for k1 in 0..<64 {                      // step 3, per k1: 15-pt DFT over n2
                    for k2 in 0..<15 {
                        var sr: Float = 0, si: Float = 0
                        for v in 0..<15 {
                            let br = brp[v * 64 + k1], bi = bip[v * 64 + k1]
                            let c = wc[v * 15 + k2], s = ws[v * 15 + k2]
                            sr += br * c - bi * s; si += br * s + bi * c
                        }
                        orp[64 * k2 + k1] = sr; oip[64 * k2 + k1] = si
                    }
                }
            } } } }
        } } } } } }
    }

    func forwardReal(_ x: [Float], offset: Int, window: [Float]) {
        ar.withUnsafeMutableBufferPointer { arp in ai.withUnsafeMutableBufferPointer { aip in
            x.withUnsafeBufferPointer { xp in window.withUnsafeBufferPointer { wp in
                for i in 0..<960 { arp[i] = xp[offset + i] * wp[i]; aip[i] = 0 }
            } }
        } }
        run()
    }
    func forwardComplex(_ xr: [Float], _ xi: [Float]) {
        ar.withUnsafeMutableBufferPointer { arp in ai.withUnsafeMutableBufferPointer { aip in
            xr.withUnsafeBufferPointer { xrp in xi.withUnsafeBufferPointer { xip in
                for i in 0..<960 { arp[i] = xrp[i]; aip[i] = xip[i] }
            } }
        } }
        run()
    }
}

// Bluestein's algorithm: an arbitrary-N DFT via a power-of-two FFT (kept as a
// general fallback for non-960 sizes). `outR`/`outI` hold the unscaled DFT.
final class BluesteinDFT {
    let nn: Int, mm: Int
    private let fft: Radix2FFT
    private let wRe: [Float], wIm: [Float], fbRe: [Float], fbIm: [Float]
    private var ar: [Float], ai: [Float]
    private(set) var outR: [Float], outI: [Float]

    init(_ N: Int) {
        nn = N
        var m = 1; while m < 2 * N - 1 { m <<= 1 }
        mm = m
        fft = Radix2FFT(n: m)
        var wr = [Float](repeating: 0, count: N), wi = [Float](repeating: 0, count: N)
        for k in 0..<N {
            let ang = Float.pi * Float((k * k) % (2 * N)) / Float(N)   // exp(-i pi k^2/N)
            wr[k] = cosf(ang); wi[k] = -sinf(ang)
        }
        wRe = wr; wIm = wi
        var br = [Float](repeating: 0, count: m), bi = [Float](repeating: 0, count: m)
        br[0] = wr[0]; bi[0] = -wi[0]                 // conj(w[0])
        for k in 1..<N { let r = wr[k], im = -wi[k]; br[k] = r; bi[k] = im; br[m - k] = r; bi[m - k] = im }
        fft.transform(&br, &bi, inverse: false)
        fbRe = br; fbIm = bi
        ar = [Float](repeating: 0, count: m); ai = [Float](repeating: 0, count: m)
        outR = [Float](repeating: 0, count: N); outI = [Float](repeating: 0, count: N)
    }

    // Runs the convolution over already-loaded `ar`/`ai` and writes `outR`/`outI`.
    private func run(_ arp: UnsafeMutablePointer<Float>, _ aip: UnsafeMutablePointer<Float>) {
        fft.transform(arp, aip, inverse: false)
        fbRe.withUnsafeBufferPointer { fr in fbIm.withUnsafeBufferPointer { fi in
            for i in 0..<mm { let r = arp[i] * fr[i] - aip[i] * fi[i]; let m = arp[i] * fi[i] + aip[i] * fr[i]; arp[i] = r; aip[i] = m }
        } }
        fft.transform(arp, aip, inverse: true)
        wRe.withUnsafeBufferPointer { wr in wIm.withUnsafeBufferPointer { wi in
            outR.withUnsafeMutableBufferPointer { orp in outI.withUnsafeMutableBufferPointer { oip in
                for k in 0..<nn { orp[k] = arp[k] * wr[k] - aip[k] * wi[k]; oip[k] = arp[k] * wi[k] + aip[k] * wr[k] }
            } }
        } }
    }
    /// Forward DFT of a real frame `x[offset..<offset+nn]` * `window` into `outR`/`outI`.
    func forwardReal(_ x: [Float], offset: Int, window: [Float]) {
        ar.withUnsafeMutableBufferPointer { arb in ai.withUnsafeMutableBufferPointer { aib in
            let arp = arb.baseAddress!, aip = aib.baseAddress!
            x.withUnsafeBufferPointer { xp in window.withUnsafeBufferPointer { wp in
                wRe.withUnsafeBufferPointer { wr in wIm.withUnsafeBufferPointer { wi in
                    for n in 0..<nn { let v = xp[offset + n] * wp[n]; arp[n] = v * wr[n]; aip[n] = v * wi[n] }
                } }
            } }
            for n in nn..<mm { arp[n] = 0; aip[n] = 0 }
            run(arp, aip)
        } }
    }
    /// Forward DFT of complex input (length nn) into `outR`/`outI`.
    func forwardComplex(_ xr: [Float], _ xi: [Float]) {
        ar.withUnsafeMutableBufferPointer { arb in ai.withUnsafeMutableBufferPointer { aib in
            let arp = arb.baseAddress!, aip = aib.baseAddress!
            xr.withUnsafeBufferPointer { xrp in xi.withUnsafeBufferPointer { xip in
                wRe.withUnsafeBufferPointer { wr in wIm.withUnsafeBufferPointer { wi in
                    for n in 0..<nn { arp[n] = xrp[n] * wr[n] - xip[n] * wi[n]; aip[n] = xrp[n] * wi[n] + xip[n] * wr[n] }
                } }
            } }
            for n in nn..<mm { arp[n] = 0; aip[n] = 0 }
            run(arp, aip)
        } }
    }
}
#endif

/// STFT/ISTFT matching DFN's reference (`libDF/src/lib.rs`): Vorbis window,
/// n_fft 960, hop 480, forward gain `wnorm = 2*hop/n_fft^2 = 1/960`. Framing
/// prepends `n_fft - hop = 480` zeros and drops the same from synthesis to undo
/// the analysis-synthesis delay. Real-DFT as a matmul so it needs no power-of-two.
final class ClearSTFT {
    let fftSize: Int
    let hopSize: Int
    let nFreq: Int
    private let window: [Float]
    private let wnorm: Float
    #if canImport(Accelerate)
    private let fwd: vDSP_DFT_Setup
    private let inv: vDSP_DFT_Setup
    #else
    private var pool: [MixedFFT960] = []      // one FFT per worker thread (lazy)
    #endif

    init(fftSize: Int = ClearDSP.fftSize, hopSize: Int = ClearDSP.hopSize) {
        self.fftSize = fftSize
        self.hopSize = hopSize
        let f = fftSize / 2 + 1
        self.nFreq = f

        // Vorbis window: sin(pi/2 * sin^2(pi/2 * (n+0.5)/halfN)).
        var w = [Float](repeating: 0, count: fftSize)
        let halfN = Double(fftSize / 2)
        for n in 0..<fftSize {
            let s = sin(0.5 * .pi * (Double(n) + 0.5) / halfN)
            w[n] = Float(sin(0.5 * .pi * s * s))
        }
        self.window = w
        self.wnorm = Float(2 * hopSize) / Float(fftSize * fftSize)

        #if canImport(Accelerate)
        fwd = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)!
        inv = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(fftSize), .INVERSE)!
        #else
        _ = f
        precondition(fftSize == 960, "portable path is specialized for n_fft 960")
        #endif
    }

    #if canImport(Accelerate)
    deinit { vDSP_DFT_DestroySetup(fwd); vDSP_DFT_DestroySetup(inv) }
    #else
    // Cap parallel workers; wasm (single-threaded) runs concurrentPerform serially.
    static var maxWorkers: Int {
        #if os(WASI)
        1
        #elseif os(Android)
        2
        #else
        max(1, min(ProcessInfo.processInfo.activeProcessorCount, 16))
        #endif
    }
    private func ensurePool(_ n: Int) { while pool.count < n { pool.append(MixedFFT960()) } }
    /// Split `count` items across `workers` and run `body(worker, lo, hi)` in
    /// parallel (serial when workers <= 1, e.g. on wasm).
    static func forEachRange(count: Int, workers: Int, _ body: @Sendable (Int, Int, Int) -> Void) {
        #if canImport(Dispatch)
        guard workers > 1 else { if count > 0 { body(0, 0, count) }; return }
        let per = (count + workers - 1) / workers
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            let lo = w * per, hi = min(count, lo + per)
            if lo < hi { body(w, lo, hi) }
        }
        #else
        if count > 0 { body(0, 0, count) }   // wasm: no Dispatch, run serially
        #endif
    }
    #endif

    /// Windowed frames -> (real, imag) spectrogram, frame-major [nFrames x nFreq].
    func forward(_ audio: [Float]) -> (real: [Float], imag: [Float], nFrames: Int) {
        let prePad = fftSize - hopSize
        var padded = [Float](repeating: 0, count: prePad + audio.count)
        padded.withUnsafeMutableBufferPointer { dp in
            audio.withUnsafeBufferPointer { sp in
                if let s = sp.baseAddress { dp.baseAddress!.advanced(by: prePad).update(from: s, count: audio.count) }
            }
        }
        return forward(prePadded: padded)
    }

    /// Same transform over a buffer the caller already laid out with the
    /// `fftSize - hopSize` analysis prepad in front (and whatever tail padding
    /// it needs). Lets a long-file pipeline build that buffer once instead of
    /// paying a second full-signal copy here: at 48 kHz a 33-minute signal is
    /// 363 MB, so the copy is worth avoiding.
    func forward(prePadded padded: [Float]) -> (real: [Float], imag: [Float], nFrames: Int) {
        guard padded.count >= fftSize else { return ([], [], 0) }
        let nFrames = (padded.count - fftSize) / hopSize + 1
        var re = [Float](repeating: 0, count: nFrames * nFreq)
        var im = [Float](repeating: 0, count: nFrames * nFreq)

        #if canImport(Accelerate)
        let n = fftSize, f = nFreq
        let iIn = [Float](repeating: 0, count: n)
        var rIn = [Float](repeating: 0, count: n)
        var rOut = [Float](repeating: 0, count: n), iOut = [Float](repeating: 0, count: n)
        var scale = wnorm
        for t in 0..<nFrames {
            let off = t * hopSize
            padded.withUnsafeBufferPointer { p in vDSP_vmul(p.baseAddress! + off, 1, window, 1, &rIn, 1, vDSP_Length(n)) }
            vDSP_DFT_Execute(fwd, rIn, iIn, &rOut, &iOut)
            re.withUnsafeMutableBufferPointer { vDSP_vsmul(rOut, 1, &scale, $0.baseAddress! + t * f, 1, vDSP_Length(f)) }
            im.withUnsafeMutableBufferPointer { vDSP_vsmul(iOut, 1, &scale, $0.baseAddress! + t * f, 1, vDSP_Length(f)) }
        }
        #else
        // Frames are independent; run the per-frame FFTs across all cores, each
        // worker with its own FFT scratch. Disjoint writes into re/im.
        let workers = min(nFrames, Self.maxWorkers)
        ensurePool(workers)
        let scale = wnorm, hop = hopSize, f2 = nFreq
        re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
            let box = Unchecked((rp.baseAddress!, ip.baseAddress!, self.pool, padded, window))
            Self.forEachRange(count: nFrames, workers: workers) { w, lo, hi in
                let (rpb, ipb, pool, padded, win) = box.value
                let dft = pool[w]
                for t in lo..<hi {
                    dft.forwardReal(padded, offset: t * hop, window: win)
                    let base = t * f2
                    dft.outR.withUnsafeBufferPointer { orp in dft.outI.withUnsafeBufferPointer { oip in
                        for k in 0..<f2 { rpb[base + k] = scale * orp[k]; ipb[base + k] = scale * oip[k] }
                    } }
                }
            }
        } }
        #endif
        return (re, im, nFrames)
    }

    /// (real, imag) spectrogram -> time signal (windowed COLA overlap-add),
    /// dropping the analysis-synthesis prepad.
    func inverse(real: [Float], imag: [Float], nFrames: Int) -> [Float] {
        real.withUnsafeBufferPointer { rp in
            imag.withUnsafeBufferPointer { ip in
                inverse(real: rp.baseAddress!, imag: ip.baseAddress!, nFrames: nFrames)
            }
        }
    }

    /// Pointer form, so a caller holding the spectrum in its own scratch buffers
    /// can synthesize without first copying them into `Array`s. Two full
    /// spectrogram planes are 726 MB for a 33-minute file.
    func inverse(real: UnsafePointer<Float>, imag: UnsafePointer<Float>, nFrames: Int) -> [Float] {
        let prePad = fftSize - hopSize
        guard nFrames > 0 else { return [] }
        let rawLen = (nFrames - 1) * hopSize + fftSize
        var out = [Float](repeating: 0, count: rawLen)

        #if canImport(Accelerate)
        let n = fftSize, f = nFreq, mirror = fftSize - nFreq
        var rSpec = [Float](repeating: 0, count: n), iSpec = [Float](repeating: 0, count: n)
        var rTime = [Float](repeating: 0, count: n), iTime = [Float](repeating: 0, count: n)
        for t in 0..<nFrames {
            let base = t * f
            _ = memcpy(&rSpec, real + base, f * 4)
            _ = memcpy(&iSpec, imag + base, f * 4)
            if mirror > 0 {
                rSpec.withUnsafeMutableBufferPointer { dp in
                    memcpy(dp.baseAddress! + f, real + base + 1, mirror * 4)
                    vDSP_vrvrs(dp.baseAddress! + f, 1, vDSP_Length(mirror))
                }
                iSpec.withUnsafeMutableBufferPointer { dp in
                    memcpy(dp.baseAddress! + f, imag + base + 1, mirror * 4)
                    vDSP_vrvrs(dp.baseAddress! + f, 1, vDSP_Length(mirror))
                    vDSP_vneg(dp.baseAddress! + f, 1, dp.baseAddress! + f, 1, vDSP_Length(mirror))
                }
            }
            vDSP_DFT_Execute(inv, rSpec, iSpec, &rTime, &iTime)
            let off = t * hopSize
            out.withUnsafeMutableBufferPointer { op in
                vDSP_vma(rTime, 1, window, 1, op.baseAddress! + off, 1, op.baseAddress! + off, 1, vDSP_Length(n))
            }
        }
        #else
        // Per-frame windowed time (idft = conj(dft(conj(X)))) computed in
        // parallel into a per-frame buffer; the overlap-add sum is then serial
        // (adjacent frames overlap by fftSize-hop, so it can't parallelize).
        let workers = min(nFrames, Self.maxWorkers)
        ensurePool(workers)
        let fft = fftSize, f2 = nFreq
        var recon = [Float](repeating: 0, count: nFrames * fftSize)
        recon.withUnsafeMutableBufferPointer { rc in
            let box = Unchecked((rc.baseAddress!, self.pool, real, imag, window))
            Self.forEachRange(count: nFrames, workers: workers) { w, lo, hi in
                let (rcb, pool, real, imag, win) = box.value
                let dft = pool[w]
                var Xr = [Float](repeating: 0, count: fft), Xi = [Float](repeating: 0, count: fft)
                for t in lo..<hi {
                    let base = t * f2
                    for k in 0..<f2 { Xr[k] = real[base + k]; Xi[k] = -imag[base + k] }
                    for k in 1..<(f2 - 1) { Xr[fft - k] = real[base + k]; Xi[fft - k] = imag[base + k] }
                    dft.forwardComplex(Xr, Xi)
                    dft.outR.withUnsafeBufferPointer { orp in win.withUnsafeBufferPointer { wp in
                        for n in 0..<fft { rcb[t * fft + n] = orp[n] * wp[n] }
                    } }
                }
            }
            let rcb = rc.baseAddress!
            for t in 0..<nFrames { let off = t * hopSize; for n in 0..<fft { out[off + n] += rcb[t * fft + n] } }
        }
        #endif
        // Dropping the prepad in place: `Array(out[prePad...])` would hold a
        // second full-length buffer alongside `out`.
        if rawLen > prePad { out.removeFirst(prePad) }
        return out
    }
}
