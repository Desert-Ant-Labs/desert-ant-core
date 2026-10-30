// The Kaldi log-mel filterbank the trunk was trained on. It lives outside the
// graphs because float16 underflows the quiet bins of a power spectrum.
//
// The arithmetic runs on Accelerate on Apple platforms and on plain loops
// everywhere else; `-D WHO_PORTABLE_DSP` picks the loops on a Mac, so their
// parity with the goldens can be checked without a Linux box.

import Foundation
import RealModule

#if canImport(Accelerate) && !WHO_PORTABLE_DSP
import Accelerate
#endif

/// A forward DFT of one frame; read-only once created, so shared between threads. vDSP's complex DFT on
/// Apple platforms; elsewhere a radix-2 FFT when the length is a power of two, and the cosine and sine bases
/// as tables otherwise, where only the first `count / 2 + 1` bins are computed, the ones a power spectrum reads.
final class DFTSetup: @unchecked Sendable {
    let count: Int
    #if canImport(Accelerate) && !WHO_PORTABLE_DSP
    private let setup: vDSP_DFT_Setup
    #else
    private let bins: Int
    /// Radix-2: the bit-reversed order of the inputs and the twiddles `exp(-2 pi i k / count)` for k < count / 2,
    /// in double so the quietest bins, where the log sits near its floor, see the signal's leakage and not the
    /// transform's.
    private let reversed: [Int]
    private let twiddleRe: [Double]
    private let twiddleIm: [Double]
    /// The tables for a length that is not a power of two.
    private let cosines: [Float]
    private let sines: [Float]
    private var radix2: Bool { !reversed.isEmpty }
    #endif

    init(count: Int) throws {
        self.count = count
        #if canImport(Accelerate) && !WHO_PORTABLE_DSP
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(count), vDSP_DFT_Direction.FORWARD) else {
            throw WhoError.invalidModel("no DFT of length \(count)")
        }
        self.setup = setup
        #else
        guard count > 0 else { throw WhoError.invalidModel("no DFT of length \(count)") }
        bins = count / 2 + 1
        if count & (count - 1) == 0, count >= 2 {
            var bits = 0
            while (1 << bits) < count { bits += 1 }
            reversed = (0..<count).map { i in
                var x = i, r = 0
                for _ in 0..<bits { r = (r << 1) | (x & 1); x >>= 1 }
                return r
            }
            twiddleRe = (0..<(count / 2)).map { cos(2.0 * Double.pi * Double($0) / Double(count)) }
            twiddleIm = (0..<(count / 2)).map { -sin(2.0 * Double.pi * Double($0) / Double(count)) }
            cosines = []
            sines = []
        } else {
            reversed = []
            twiddleRe = []
            twiddleIm = []
            var cosines = [Float](repeating: 0, count: bins * count)
            var sines = [Float](repeating: 0, count: bins * count)
            for k in 0..<bins {
                for n in 0..<count {
                    let angle = 2.0 * Double.pi * Double(k * n % count) / Double(count)
                    cosines[k * count + n] = Float(cos(angle))
                    sines[k * count + n] = Float(-sin(angle))
                }
            }
            self.cosines = cosines
            self.sines = sines
        }
        #endif
    }

    #if canImport(Accelerate) && !WHO_PORTABLE_DSP
    deinit { vDSP_DFT_DestroySetup(setup) }
    #endif

    /// The transform of `real` (the imaginary input is zero for a frame of samples). `outReal` and
    /// `outImaginary` hold `count` values; on the portable path only the first `count / 2 + 1` are written.
    func transform(real: [Float], imaginary: [Float], outReal: inout [Float], outImaginary: inout [Float]) {
        #if canImport(Accelerate) && !WHO_PORTABLE_DSP
        vDSP_DFT_Execute(setup, real, imaginary, &outReal, &outImaginary)
        #else
        if radix2 {
            fft(real, outReal: &outReal, outImaginary: &outImaginary)
            return
        }
        real.withUnsafeBufferPointer { x in
            cosines.withUnsafeBufferPointer { c in
                sines.withUnsafeBufferPointer { s in
                    for k in 0..<bins {
                        var re: Float = 0, im: Float = 0
                        let row = k * count
                        for n in 0..<count {
                            re += x[n] * c[row + n]
                            im += x[n] * s[row + n]
                        }
                        outReal[k] = re
                        outImaginary[k] = im
                    }
                }
            }
        }
        #endif
    }

    #if !canImport(Accelerate) || WHO_PORTABLE_DSP
    /// Iterative radix-2 in double, in place over the bit-reversed input, the whole spectrum written as float.
    private func fft(_ real: [Float], outReal: inout [Float], outImaginary: inout [Float]) {
        var re = [Double](repeating: 0, count: count)
        var im = [Double](repeating: 0, count: count)
        for i in 0..<count { re[i] = Double(real[reversed[i]]) }
        re.withUnsafeMutableBufferPointer { re in
            im.withUnsafeMutableBufferPointer { im in
                twiddleRe.withUnsafeBufferPointer { wr in
                    twiddleIm.withUnsafeBufferPointer { wi in
                        var size = 2
                        while size <= count {
                            let half = size / 2, step = count / size
                            var start = 0
                            while start < count {
                                var k = 0
                                for j in 0..<half {
                                    let a = start + j, b = a + half
                                    let tr = re[b] * wr[k] - im[b] * wi[k]
                                    let ti = re[b] * wi[k] + im[b] * wr[k]
                                    re[b] = re[a] - tr
                                    im[b] = im[a] - ti
                                    re[a] += tr
                                    im[a] += ti
                                    k += step
                                }
                                start += size
                            }
                            size *= 2
                        }
                    }
                }
            }
        }
        for i in 0..<count {
            outReal[i] = Float(re[i])
            outImaginary[i] = Float(im[i])
        }
    }
    #endif
}

/// The vector arithmetic the frontend needs, in Accelerate's terms on Apple platforms and as loops elsewhere.
private enum Vec {
    /// `[m x n]` row-major transposed to `[n x m]`.
    static func transpose(_ a: [Float], rows m: Int, columns n: Int) -> [Float] {
        var out = [Float](repeating: 0, count: m * n)
        #if canImport(Accelerate) && !WHO_PORTABLE_DSP
        vDSP_mtrans(a, 1, &out, 1, vDSP_Length(n), vDSP_Length(m))
        #else
        for i in 0..<m { for j in 0..<n { out[j * m + i] = a[i * n + j] } }
        #endif
        return out
    }

    /// The sum of `count` values from `start`, `stride` apart.
    static func sum(_ a: [Float], from start: Int, stride: Int, count: Int) -> Float {
        #if canImport(Accelerate) && !WHO_PORTABLE_DSP
        var out: Float = 0
        a.withUnsafeBufferPointer { vDSP_sve($0.baseAddress! + start, stride, &out, vDSP_Length(count)) }
        return out
        #else
        var out: Double = 0
        var i = start
        for _ in 0..<count { out += Double(a[i]); i += stride }
        return Float(out)
        #endif
    }

    /// `a[offset ..< offset + b.count] -= b`.
    static func subtract(_ b: [Float], from a: inout [Float], at offset: Int) {
        #if canImport(Accelerate) && !WHO_PORTABLE_DSP
        a.withUnsafeMutableBufferPointer { vDSP_vsub(b, 1, $0.baseAddress! + offset, 1, $0.baseAddress! + offset, 1, vDSP_Length(b.count)) }
        #else
        for i in 0..<b.count { a[offset + i] -= b[i] }
        #endif
    }

    /// `c[m x n] = a[m x k] @ b[k x n]`, all row-major.
    static func matmul(_ a: [Float], _ b: [Float], rows m: Int, inner k: Int, columns n: Int) -> [Float] {
        var c = [Float](repeating: 0, count: m * n)
        #if canImport(Accelerate) && !WHO_PORTABLE_DSP
        vDSP_mmul(a, 1, b, 1, &c, 1, vDSP_Length(m), vDSP_Length(n), vDSP_Length(k))
        #else
        var row = [Double](repeating: 0, count: n)
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                c.withUnsafeMutableBufferPointer { pc in
                    for i in 0..<m {
                        for j in 0..<n { row[j] = 0 }
                        for l in 0..<k {
                            let x = Double(pa[i * k + l])
                            if x == 0 { continue }
                            let rowB = l * n
                            for j in 0..<n { row[j] += x * Double(pb[rowB + j]) }
                        }
                        for j in 0..<n { pc[i * n + j] = Float(row[j]) }
                    }
                }
            }
        }
        #endif
        return c
    }

    /// `log(max(a, floor))`, in place.
    static func logFloored(_ a: inout [Float], floor: Float) {
        #if canImport(Accelerate) && !WHO_PORTABLE_DSP
        var low = floor
        vDSP_vthr(a, 1, &low, &a, 1, vDSP_Length(a.count))
        var n = Int32(a.count)
        vvlogf(&a, a, &n)
        #else
        for i in a.indices { a[i] = Float.log(max(a[i], floor)) }
        #endif
    }

    static func mean(_ a: UnsafePointer<Float>, count: Int) -> Float {
        #if canImport(Accelerate) && !WHO_PORTABLE_DSP
        var out: Float = 0
        vDSP_meanv(a, 1, &out, vDSP_Length(count))
        return out
        #else
        var out: Double = 0
        for i in 0..<count { out += Double(a[i]) }
        return Float(out / Double(count))
        #endif
    }

    /// `out[i] = a[i] * b[i]` for the first `count`.
    static func multiply(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, into out: UnsafeMutablePointer<Float>, count: Int) {
        #if canImport(Accelerate) && !WHO_PORTABLE_DSP
        vDSP_vmul(a, 1, b, 1, out, 1, vDSP_Length(count))
        #else
        for i in 0..<count { out[i] = a[i] * b[i] }
        #endif
    }
}

/// Samples to the centred log-mel frames the trunk graph consumes. Immutable after `init`.
struct Frontend: @unchecked Sendable {
    /// The frontend's constants, read from `who_meta.json`.
    struct Geometry: Sendable, Equatable {
        let sampleRate: Int
        /// Samples per frame (25 ms) and between frames (10 ms).
        let frame: Int
        let shift: Int
        let nFFT: Int
        let mels: Int
        let preemphasis: Float
        /// Samples are scaled to the 16-bit integer range before framing, as Kaldi reads them.
        let scale: Float
        let logFloor: Float

        var bins: Int { nFFT / 2 + 1 }
    }

    let geometry: Geometry
    /// `[bins * mels]` row-major, so a frame's mel energies are one `power[1 x bins] @ banks[bins x mels]`.
    private let banksTransposed: [Float]
    /// Symmetric Hamming, `0.54 - 0.46 cos(2 pi n / (N - 1))`: Kaldi's and torch's `periodic=False`.
    private let window: [Float]
    private let dft: DFTSetup

    /// Only frames that fit completely, Kaldi's `snip_edges`.
    func frames(for samples: Int) -> Int {
        samples < geometry.frame ? 0 : 1 + (samples - geometry.frame) / geometry.shift
    }

    init(geometry: Geometry, banksTable: [UInt8]) throws {
        self.geometry = geometry
        let (banks, mels, bins) = try Frontend.parseBanks(banksTable)
        guard mels == geometry.mels, bins == geometry.bins else {
            throw WhoError.invalidModel("mel bank table is \(mels) x \(bins), the geometry says \(geometry.mels) x \(geometry.bins)")
        }
        banksTransposed = Vec.transpose(banks, rows: mels, columns: bins)
        let n = geometry.frame
        window = (0..<n).map { 0.54 - 0.46 * Float(cos(2.0 * Double.pi * Double($0) / Double(n - 1))) }
        dft = try DFTSetup(count: geometry.nFFT)
    }

    /// `[mels, bins]` as two little-endian UInt32, then the rows as little-endian Float32.
    static func parseBanks(_ bytes: [UInt8]) throws -> (banks: [Float], mels: Int, bins: Int) {
        guard bytes.count >= 8 else { throw WhoError.invalidModel("mel bank table is truncated") }
        func u32(_ at: Int) -> Int {
            Int(UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
        }
        let mels = u32(0), bins = u32(4)
        guard mels > 0, bins > 0, bytes.count == 8 + 4 * mels * bins else {
            throw WhoError.invalidModel("mel bank table of \(mels) x \(bins) does not match \(bytes.count) bytes")
        }
        var banks = [Float](repeating: 0, count: mels * bins)
        bytes.withUnsafeBytes { raw in
            for i in 0..<(mels * bins) {
                banks[i] = Float(bitPattern: raw.loadUnaligned(fromByteOffset: 8 + 4 * i, as: UInt32.self).littleEndian)
            }
        }
        return (banks, mels, bins)
    }

    /// Each mel's mean over the recording, the first of the log-mel's two passes: the second reads any span of
    /// frames against it, so no recording-long feature array is ever held. Summed in double, `pieceFrames` at a time.
    func means(_ samples: [Float], pieceFrames: Int = 6000) -> (means: [Float], frames: Int) {
        let total = frames(for: samples.count)
        let chunks = stride(from: 0, to: total, by: pieceFrames).map {
            Frontend.sums([self], samples: samples, firstFrame: $0, frames: min(pieceFrames, total - $0))[0]
        }
        return (Frontend.average(chunks, frames: total, mels: geometry.mels), total)
    }

    /// Whether `other` computes the same power spectrum of every frame: all constants alike but the mel bands
    /// and the log floor, which act after it.
    func sharesSpectrum(with other: Frontend) -> Bool {
        let a = geometry, b = other.geometry
        return a.sampleRate == b.sampleRate && a.frame == b.frame && a.shift == b.shift && a.nFFT == b.nFFT
            && a.preemphasis == b.preemphasis && a.scale == b.scale
    }

    /// `means` for several frontends that share their spectrum, from one spectrum per frame, with up to `workers`
    /// of `means`'s chunks computed at once. Each chunk's sums are the ones `means` takes and are added in chunk
    /// order, so every frontend's means equal its own `means`, to the bit. Two workers, not more: each chunk holds
    /// about 9 MB while it runs, and on an M5 Pro four raised a long recording's peak footprint by 10 MB for 3 %.
    static func means(_ frontends: [Frontend], samples: [Float], pieceFrames: Int = 6000, workers: Int = 2) async -> (means: [[Float]], frames: Int) {
        let first = frontends[0]
        precondition(frontends.allSatisfy { first.sharesSpectrum(with: $0) }, "the frontends compute different spectra")
        let total = first.frames(for: samples.count)
        let starts = Array(stride(from: 0, to: total, by: pieceFrames))
        var chunks = [[[Float]]](repeating: [], count: starts.count)
        await withTaskGroup(of: (chunk: Int, sums: [[Float]]).self) { group in
            var issued = 0
            func issue() {
                let chunk = issued, start = starts[chunk]
                group.addTask { (chunk, Frontend.sums(frontends, samples: samples, firstFrame: start, frames: min(pieceFrames, total - start))) }
                issued += 1
            }
            while issued < min(max(workers, 1), starts.count) { issue() }
            while let done = await group.next() {
                chunks[done.chunk] = done.sums
                if issued < starts.count { issue() }
            }
        }
        let means = frontends.indices.map { f in Frontend.average(chunks.map { $0[f] }, frames: total, mels: frontends[f].geometry.mels) }
        return (means, total)
    }

    /// For each frontend, each mel's sum over `frames` frames from `firstFrame`, from one power spectrum.
    private static func sums(_ frontends: [Frontend], samples: [Float], firstFrame: Int, frames: Int) -> [[Float]] {
        let power = frontends[0].powerSpectra(samples, firstFrame: firstFrame, frames: frames)
        return frontends.map { frontend in
            let mel = frontend.logMel(power: power, frames: frames)
            let mels = frontend.geometry.mels
            return (0..<mels).map { Vec.sum(mel, from: $0, stride: mels, count: frames) }
        }
    }

    /// The chunks' sums as means: added in double, in chunk order.
    private static func average(_ chunks: [[Float]], frames total: Int, mels: Int) -> [Float] {
        var sums = [Double](repeating: 0, count: mels)
        for chunk in chunks {
            for m in 0..<mels { sums[m] += Double(chunk[m]) }
        }
        return total > 0 ? sums.map { Float($0 / Double(total)) } : [Float](repeating: 0, count: mels)
    }

    /// The log-mel of the frames in `range`, `[range.count * mels]` row-major, each mel's `means` removed.
    func features(_ samples: [Float], frames range: Range<Int>, means: [Float]) -> [Float] {
        let mels = geometry.mels
        var out = logMel(samples, firstFrame: range.lowerBound, frames: range.count)
        for f in 0..<range.count {
            Vec.subtract(means, from: &out, at: f * mels)
        }
        return out
    }

    /// The log-mel of a whole recording, `[frames * mels]` row-major, each mel's mean over the recording removed:
    /// both passes, for a recording short enough to hold whole.
    func features(_ samples: [Float], pieceFrames: Int = 6000) -> (values: [Float], frames: Int) {
        let (means, total) = means(samples, pieceFrames: pieceFrames)
        let mels = geometry.mels
        var out = [Float](repeating: 0, count: total * mels)
        var piece = 0
        while piece < total {
            let count = min(pieceFrames, total - piece)
            out.replaceSubrange((piece * mels)..<((piece + count) * mels), with: features(samples, frames: piece..<(piece + count), means: means))
            piece += count
        }
        return (out, total)
    }

    /// The log-mel energies of `frames` consecutive frames from `firstFrame`, `[frames * mels]`, before the mean is removed.
    private func logMel(_ samples: [Float], firstFrame: Int, frames: Int) -> [Float] {
        guard frames > 0 else { return [] }
        return logMel(power: powerSpectra(samples, firstFrame: firstFrame, frames: frames), frames: frames)
    }

    /// The log-mel energies of `frames` power spectra, `[frames * bins]` in, `[frames * mels]` out.
    private func logMel(power: [Float], frames: Int) -> [Float] {
        var mel = Vec.matmul(power, banksTransposed, rows: frames, inner: geometry.bins, columns: geometry.mels)
        Vec.logFloored(&mel, floor: geometry.logFloor)
        return mel
    }

    /// `|rfft|^2` of `frames` consecutive frames from `firstFrame`, `[frames * bins]`. Per frame, Kaldi's
    /// order: the samples scaled to the 16-bit range, mean removed, pre-emphasis against the previous sample,
    /// the window, zero padding to `nFFT`.
    private func powerSpectra(_ samples: [Float], firstFrame: Int, frames: Int) -> [Float] {
        let g = geometry
        var power = [Float](repeating: 0, count: frames * g.bins)
        var re = [Float](repeating: 0, count: g.nFFT)
        let im = [Float](repeating: 0, count: g.nFFT)
        var outRe = [Float](repeating: 0, count: g.nFFT)
        var outIm = [Float](repeating: 0, count: g.nFFT)
        var frame = [Float](repeating: 0, count: g.frame)
        // Raw buffers in the per-sample loops: through Array's subscript every element paid a bounds and a
        // uniqueness check, a quarter of the filterbank's time. The arithmetic and its order are the same.
        // `re` past `g.frame` stays the zero padding: only the window's product writes it, and only below.
        samples.withUnsafeBufferPointer { x in
            window.withUnsafeBufferPointer { w in
                power.withUnsafeMutableBufferPointer { p in
                    frame.withUnsafeMutableBufferPointer { s in
                        for f in 0..<frames {
                            let start = (firstFrame + f) * g.shift
                            for i in 0..<g.frame { s[i] = x[start + i] * g.scale }
                            let mean = Vec.mean(s.baseAddress!, count: g.frame)
                            for i in 0..<g.frame { s[i] -= mean }
                            // From the end, so each sample still sees its unmodified predecessor.
                            for i in stride(from: g.frame - 1, through: 1, by: -1) { s[i] -= g.preemphasis * s[i - 1] }
                            s[0] -= g.preemphasis * s[0]
                            re.withUnsafeMutableBufferPointer { r in
                                Vec.multiply(s.baseAddress!, w.baseAddress!, into: r.baseAddress!, count: g.frame)
                            }
                            dft.transform(real: re, imaginary: im, outReal: &outRe, outImaginary: &outIm)
                            outRe.withUnsafeBufferPointer { a in
                                outIm.withUnsafeBufferPointer { b in
                                    let row = f * g.bins
                                    for k in 0..<g.bins { p[row + k] = a[k] * a[k] + b[k] * b[k] }
                                }
                            }
                        }
                    }
                }
            }
        }
        return power
    }
}
