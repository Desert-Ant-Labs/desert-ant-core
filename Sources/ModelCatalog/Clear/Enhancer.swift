// Enhancement over an arbitrary-length mono signal: STFT -> DFN features ->
// fixed-window model (via desert-ant-core's InferenceSession, so the same code
// runs Core ML on Apple, LiteRT on Android/Linux, and the JS host on the web)
// -> scatter enhanced spectrum -> ISTFT. Ported from clear-swift's Inference
// chunk loop; tensors are float32 (LiteRT's I/O type; Core ML casts fp16).
//
// The model is a fixed 200-frame window and each chunk is independent, so on
// native platforms the chunk loop runs across a pool of sessions (one per
// worker) to use multiple cores; the native LiteRT runtime is otherwise
// single-threaded. Apple (fast, single session) and wasm (its LiteRT.js host is
// already multi-threaded) use one session.

import Foundation
import DesertAnt
#if canImport(Accelerate)
import Accelerate
#endif

/// Counts finished chunks across the worker pool and reports the fraction.
/// A lock rather than an actor so a worker never suspends to report.
private final class ChunkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int
    private let report: (@Sendable (Double) -> Void)?
    private var done = 0

    init(total: Int, report: (@Sendable (Double) -> Void)?) {
        self.total = max(1, total)
        self.report = report
    }

    func finishOne() {
        guard let report else { return }
        lock.lock()
        done += 1
        let fraction = min(1, Double(done) / Double(total))
        lock.unlock()
        report(fraction)
    }
}

struct ClearEnhancer {
    let sessions: [any InferenceSession]
    let chunkLen: Int
    private let stft = ClearSTFT()

    init(sessions: [any InferenceSession], chunkLen: Int = 200) {
        self.sessions = sessions.isEmpty ? [] : sessions
        self.chunkLen = chunkLen
    }

    /// - Parameters:
    ///   - onAnalysis: the front end (STFT then the ERB/DF feature pass),
    ///     reported as it completes each step.
    ///   - onChunk: the fraction of model chunks completed. Chunks finish out
    ///     of order across the session pool, so this counts completions rather
    ///     than positions - monotonic, but not a position in the file.
    func enhance(_ samples: [Float],
                 onAnalysis: (@Sendable (Double) -> Void)? = nil,
                 onChunk: (@Sendable (Double) -> Void)? = nil) async throws -> [Float] {
        guard !samples.isEmpty, !sessions.isEmpty else { return samples }
        let clean = sanitize(samples)
        let padded = padToWindowMultiple(clean)
        let (real, imag, nFrames) = stft.forward(padded)
        guard nFrames > 0 else { return clean }
        onAnalysis?(0.5)

        let (featErb, featSpecReal, featSpecImag) =
            ClearFeatures.compute(real: real, imag: imag, nFrames: nFrames)
        onAnalysis?(1)

        let count = real.count
        let outRe = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let outIm = UnsafeMutablePointer<Float>.allocate(capacity: count)
        outRe.initialize(repeating: 0, count: count); outIm.initialize(repeating: 0, count: count)
        defer { outRe.deinitialize(count: count); outRe.deallocate(); outIm.deinitialize(count: count); outIm.deallocate() }

        let nChunks = (nFrames + chunkLen - 1) / chunkLen
        let workers = max(1, min(sessions.count, nChunks))
        let chunkLen = self.chunkLen
        // Each worker owns one session and a strided set of chunks; output
        // ranges are disjoint per chunk, so the shared buffers need no locking.
        let box = Unchecked((outRe, outIm, sessions, featErb, featSpecReal, featSpecImag, real, imag))
        let completed = ChunkCounter(total: nChunks, report: onChunk)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for w in 0..<workers {
                group.addTask {
                    let (outRe, outIm, sessions, fe, fsr, fsi, sr, si) = box.value
                    let session = sessions[w]
                    var c = w
                    while c < nChunks {
                        let start = c * chunkLen, end = min(start + chunkLen, nFrames)
                        try await Self.runChunk(session: session, start: start, end: end, nFrames: nFrames, chunkLen: chunkLen,
                                                featErb: fe, featSpecReal: fsr, featSpecImag: fsi,
                                                specReal: sr, specImag: si, outRe: outRe, outIm: outIm)
                        completed.finishOne()
                        c += workers
                    }
                }
            }
            try await group.waitForAll()
        }

        let outReal = Array(UnsafeBufferPointer(start: outRe, count: count))
        let outImag = Array(UnsafeBufferPointer(start: outIm, count: count))
        let enhanced = stft.inverse(real: outReal, imag: outImag, nFrames: nFrames)
        return Array(enhanced.prefix(samples.count))
    }

    private static func runChunk(session: any InferenceSession, start: Int, end: Int, nFrames: Int, chunkLen: Int,
                                 featErb: [Float], featSpecReal: [Float], featSpecImag: [Float],
                                 specReal: [Float], specImag: [Float],
                                 outRe: UnsafeMutablePointer<Float>, outIm: UnsafeMutablePointer<Float>) async throws {
        let T = chunkLen
        let nFreq = ClearDSP.nFreq, nErb = ClearDSP.nErb, nDf = ClearDSP.nDf
        let look = ClearDSP.convLookahead

        var specBuf = [Float](repeating: 0, count: T * nFreq * 2)
        var erbBuf = [Float](repeating: 0, count: T * nErb)
        var featSpecBuf = [Float](repeating: 0, count: T * nDf * 2)

        let tStart = max(0, -start - look)
        let tEnd = min(T, nFrames - start - look)
        let sEnd = min(T, nFrames - start)
        #if canImport(Accelerate)
        if tEnd > tStart {
            let n = tEnd - tStart, src = start + tStart + look
            featErb.withUnsafeBufferPointer { sp in erbBuf.withUnsafeMutableBufferPointer { dp in
                _ = memcpy(dp.baseAddress! + tStart * nErb, sp.baseAddress! + src * nErb, n * nErb * 4) } }
            interleave(featSpecReal, featSpecImag, srcOffset: src * nDf, into: &featSpecBuf, dstOffset: tStart * nDf, count: n * nDf)
        }
        if sEnd > 0 {
            interleave(specReal, specImag, srcOffset: start * nFreq, into: &specBuf, dstOffset: 0, count: sEnd * nFreq)
        }
        #else
        if tEnd > tStart {
            for t in tStart..<tEnd {
                let src = start + t + look
                for f in 0..<nErb { erbBuf[t * nErb + f] = featErb[src * nErb + f] }
                for f in 0..<nDf {
                    featSpecBuf[(t * nDf + f) * 2] = featSpecReal[src * nDf + f]
                    featSpecBuf[(t * nDf + f) * 2 + 1] = featSpecImag[src * nDf + f]
                }
            }
        }
        for t in 0..<sEnd {
            let src = start + t
            for k in 0..<nFreq {
                specBuf[(t * nFreq + k) * 2] = specReal[src * nFreq + k]
                specBuf[(t * nFreq + k) * 2 + 1] = specImag[src * nFreq + k]
            }
        }
        #endif

        let outputs = try await session.run(
            inputs: [
                "spec": Tensor(float32: specBuf, shape: [1, 1, T, nFreq, 2]),
                "feat_erb": Tensor(float32: erbBuf, shape: [1, 1, T, nErb]),
                "feat_spec": Tensor(float32: featSpecBuf, shape: [1, 1, T, nDf, 2]),
            ],
            outputs: ["spec_enhanced"])
        guard let enh = outputs.first?.float32Values, enh.count >= T * nFreq * 2 else {
            throw ClearError.inferenceFailed("spec_enhanced missing or wrong size")
        }

        let validFrames = end - start
        #if canImport(Accelerate)
        let bins = validFrames * nFreq
        enh.withUnsafeBufferPointer { ep in
            var z = DSPSplitComplex(realp: outRe + start * nFreq, imagp: outIm + start * nFreq)
            ep.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) {
                vDSP_ctoz($0, 2, &z, 1, vDSP_Length(bins)) }
        }
        #else
        for t in 0..<validFrames {
            let dst = start + t
            for k in 0..<nFreq {
                outRe[dst * nFreq + k] = enh[(t * nFreq + k) * 2]
                outIm[dst * nFreq + k] = enh[(t * nFreq + k) * 2 + 1]
            }
        }
        #endif
    }

    #if canImport(Accelerate)
    private static func interleave(_ re: [Float], _ im: [Float], srcOffset: Int, into dst: inout [Float], dstOffset: Int, count: Int) {
        re.withUnsafeBufferPointer { rp in im.withUnsafeBufferPointer { ip in
            var z = DSPSplitComplex(realp: .init(mutating: rp.baseAddress! + srcOffset),
                                    imagp: .init(mutating: ip.baseAddress! + srcOffset))
            dst.withUnsafeMutableBufferPointer { dp in
                dp.baseAddress!.advanced(by: dstOffset * 2).withMemoryRebound(to: DSPComplex.self, capacity: count) {
                    vDSP_ztoc(&z, 1, $0, 2, vDSP_Length(count))
                }
            }
        } }
    }
    #endif

    private func sanitize(_ samples: [Float]) -> [Float] {
        var out = samples
        for i in 0..<out.count where !out[i].isFinite { out[i] = 0 }
        return out
    }

    private func padToWindowMultiple(_ samples: [Float]) -> [Float] {
        let hop = ClearDSP.hopSize, fft = ClearDSP.fftSize
        let needed = max(fft, ((samples.count + hop - 1) / hop) * hop + fft)
        if samples.count >= needed { return samples }
        return samples + [Float](repeating: 0, count: needed - samples.count)
    }
}
