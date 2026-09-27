// Radix-2 real FFT: a length-n real frame runs as an n/2-point complex FFT, then splits into n/2 + 1 bins.

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

struct RealFFT: Sendable {
    let n: Int
    let half: Int
    // Bit-reversal permutation of 0..<half.
    private let rev: [Int32]
    // Per-stage twiddles exp(-2 pi i j / len), stage `len` at offset len/2 - 1.
    private let twRe: [Float]
    private let twIm: [Float]
    // Split twiddles cos and sin of 2 pi k / n for k in 0...half.
    private let splitCos: [Float]
    private let splitSin: [Float]

    /// nil unless `n` is a power of two of at least 4.
    init?(n: Int) {
        guard n >= 4, n & (n - 1) == 0 else { return nil }
        self.n = n
        let m = n / 2
        self.half = m

        var bits = 0
        while (1 << bits) < m { bits += 1 }
        var r = [Int32](repeating: 0, count: m)
        for i in 0..<m {
            var x = i, y = 0
            for _ in 0..<bits { y = (y << 1) | (x & 1); x >>= 1 }
            r[i] = Int32(y)
        }
        self.rev = r

        // Twiddles in Double so table error stays below one float ulp.
        var tr = [Float](repeating: 0, count: max(m - 1, 1))
        var ti = [Float](repeating: 0, count: max(m - 1, 1))
        var len = 2
        while len <= m {
            let h = len / 2
            for j in 0..<h {
                let a = -2 * Double.pi * Double(j) / Double(len)
                tr[h - 1 + j] = Float(cos(a))
                ti[h - 1 + j] = Float(sin(a))
            }
            len <<= 1
        }
        self.twRe = tr
        self.twIm = ti

        var sc = [Float](repeating: 0, count: m + 1)
        var ss = [Float](repeating: 0, count: m + 1)
        for k in 0...m {
            let a = 2 * Double.pi * Double(k) / Double(n)
            sc[k] = Float(cos(a))
            ss[k] = Float(sin(a))
        }
        self.splitCos = sc
        self.splitSin = ss
    }

    /// Unnormalized DFT of `x * window` into `half + 1` bins; `zr`/`zi` are caller scratch of `half` floats.
    func forward(_ x: UnsafePointer<Float>, window: UnsafePointer<Float>,
                 outRe: UnsafeMutablePointer<Float>, outIm: UnsafeMutablePointer<Float>,
                 zr: UnsafeMutablePointer<Float>, zi: UnsafeMutablePointer<Float>) {
        let m = half
        rev.withUnsafeBufferPointer { rp in
            for i in 0..<m {
                let j = Int(rp[i])
                zr[j] = x[2 * i] * window[2 * i]
                zi[j] = x[2 * i + 1] * window[2 * i + 1]
            }
        }
        twRe.withUnsafeBufferPointer { twr in twIm.withUnsafeBufferPointer { twi in
            var len = 2
            while len <= m {
                let h = len >> 1
                let tr = twr.baseAddress! + (h - 1), ti = twi.baseAddress! + (h - 1)
                var i = 0
                while i < m {
                    let a = zr + i, b = zi + i
                    for j in 0..<h {
                        let c = tr[j], s = ti[j]
                        let xr = a[j + h], xi = b[j + h]
                        let pr = xr * c - xi * s, pi = xr * s + xi * c
                        let ur = a[j], ui = b[j]
                        a[j] = ur + pr; b[j] = ui + pi
                        a[j + h] = ur - pr; b[j + h] = ui - pi
                    }
                    i += len
                }
                len <<= 1
            }
        } }
        splitCos.withUnsafeBufferPointer { cp in splitSin.withUnsafeBufferPointer { sp in
            outRe[0] = zr[0] + zi[0]; outIm[0] = 0
            outRe[m] = zr[0] - zi[0]; outIm[m] = 0
            var k = 1
            while k < m {
                let ar = zr[k], ai = zi[k], br = zr[m - k], bi = zi[m - k]
                let er = 0.5 * (ar + br), ei = 0.5 * (ai - bi)
                let or = 0.5 * (ai + bi), oi = -0.5 * (ar - br)
                let c = cp[k], s = sp[k]
                outRe[k] = er + c * or + s * oi
                outIm[k] = ei + c * oi - s * or
                k += 1
            }
        } }
    }
}
