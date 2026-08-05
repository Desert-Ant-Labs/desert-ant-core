// DFN3 feature front-end: ERB-band log-power with running mean normalization,
// and unit-norm complex DF features over the first nDf bins. Ported from
// clear-swift's Features.swift (vDSP -> plain loops). The state-init ramps
// (erbState -60..-90 dB, unit-norm s 1e-3..1e-4) are load-bearing for model
// parity and must NOT be zero-initialized.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(WASILibc)
import WASILibc
#endif
#if canImport(Accelerate)
import Accelerate
#endif

enum ClearFeatures {
    /// Returns feat_erb [nFrames x nErb], and DF feat spec real/imag
    /// [nFrames x nDf] each, from a complex spectrogram [nFrames x nFreq].
    static func compute(real: [Float], imag: [Float], nFrames: Int)
        -> (featErb: [Float], featSpecReal: [Float], featSpecImag: [Float])
    {
        let nFreq = ClearDSP.nFreq, nErb = ClearDSP.nErb, nDf = ClearDSP.nDf
        let alpha = ClearDSP.normAlpha
        let oneMinus = 1 - alpha
        let widths = ClearDSP.erbWidths

        // Power |z|^2 (whole spectrogram), then mean per-bin power per ERB band.
        var erbPower = [Float](repeating: 0, count: nFrames * nErb)
        #if canImport(Accelerate)
        var power = [Float](repeating: 0, count: nFrames * nFreq)
        real.withUnsafeBufferPointer { rp in imag.withUnsafeBufferPointer { ip in
            var z = DSPSplitComplex(realp: .init(mutating: rp.baseAddress!), imagp: .init(mutating: ip.baseAddress!))
            vDSP_zvmags(&z, 1, &power, 1, vDSP_Length(power.count))
        } }
        power.withUnsafeBufferPointer { p in erbPower.withUnsafeMutableBufferPointer { o in
            for t in 0..<nFrames {
                var off = 0
                for band in 0..<nErb {
                    var s: Float = 0
                    vDSP_sve(p.baseAddress! + t * nFreq + off, 1, &s, vDSP_Length(widths[band]))
                    o[t * nErb + band] = s / Float(widths[band])
                    off += widths[band]
                }
            }
        } }
        #else
        for t in 0..<nFrames {
            let rowIn = t * nFreq, rowOut = t * nErb
            var off = 0
            for band in 0..<nErb {
                let w = widths[band]
                var sum: Float = 0
                for k in 0..<w {
                    let r = real[rowIn + off + k], m = imag[rowIn + off + k]
                    sum += r * r + m * m
                }
                erbPower[rowOut + band] = sum / Float(w)
                off += w
            }
        }
        #endif

        // ERB dB: 10*log10(power + 1e-10).
        var erbDB = erbPower
        #if canImport(Accelerate)
        var eps: Float = 1e-10, ten: Float = 10; var nLog = Int32(erbDB.count)
        vDSP_vsadd(erbDB, 1, &eps, &erbDB, 1, vDSP_Length(erbDB.count))
        vvlog10f(&erbDB, erbDB, &nLog)
        vDSP_vsmul(erbDB, 1, &ten, &erbDB, 1, vDSP_Length(erbDB.count))
        #else
        for i in 0..<erbDB.count { erbDB[i] = 10 * log10f(erbDB[i] + 1e-10) }
        #endif

        // Running-mean normalize per band; state ramps -60 -> -90 dB.
        var featErb = [Float](repeating: 0, count: nFrames * nErb)
        var erbState = [Float](repeating: 0, count: nErb)
        let mnStep: Float = (-90 - -60) / Float(nErb - 1)
        for f in 0..<nErb { erbState[f] = -60 + Float(f) * mnStep }
        for t in 0..<nFrames {
            let off = t * nErb
            for f in 0..<nErb {
                erbState[f] = erbDB[off + f] * oneMinus + erbState[f] * alpha
                featErb[off + f] = (erbDB[off + f] - erbState[f]) / 40
            }
        }

        // Unit-norm the first nDf complex bins; state s ramps 1e-3 -> 1e-4.
        var featSpecReal = [Float](repeating: 0, count: nFrames * nDf)
        var featSpecImag = [Float](repeating: 0, count: nFrames * nDf)
        var s = [Float](repeating: 0, count: nDf)
        let unStep: Float = (0.0001 - 0.001) / Float(nDf - 1)
        for f in 0..<nDf { s[f] = 0.001 + Float(f) * unStep }
        #if canImport(Accelerate)
        var mag = [Float](repeating: 0, count: nDf), inv = [Float](repeating: 0, count: nDf)
        var nDf32 = Int32(nDf); var om = oneMinus, al = alpha
        for t in 0..<nFrames {
            let inOff = t * nFreq, outOff = t * nDf
            real.withUnsafeBufferPointer { rp in imag.withUnsafeBufferPointer { ip in
                var z = DSPSplitComplex(realp: .init(mutating: rp.baseAddress! + inOff), imagp: .init(mutating: ip.baseAddress! + inOff))
                vDSP_zvabs(&z, 1, &mag, 1, vDSP_Length(nDf))
            } }
            vDSP_vsmsma(mag, 1, &om, s, 1, &al, &s, 1, vDSP_Length(nDf))  // s = mag*(1-a) + s*a
            vvrsqrtf(&inv, s, &nDf32)
            real.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + inOff, 1, inv, 1, &featSpecReal[outOff], 1, vDSP_Length(nDf)) }
            imag.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + inOff, 1, inv, 1, &featSpecImag[outOff], 1, vDSP_Length(nDf)) }
        }
        #else
        for t in 0..<nFrames {
            let inOff = t * nFreq, outOff = t * nDf
            for f in 0..<nDf {
                let r = real[inOff + f], m = imag[inOff + f]
                let mag = (r * r + m * m).squareRoot()
                s[f] = mag * oneMinus + s[f] * alpha
                let inv = 1 / s[f].squareRoot()
                featSpecReal[outOff + f] = r * inv
                featSpecImag[outOff + f] = m * inv
            }
        }
        #endif
        return (featErb, featSpecReal, featSpecImag)
    }
}
