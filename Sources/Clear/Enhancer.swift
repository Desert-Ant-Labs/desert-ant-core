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

import DesertAnt
#if canImport(Accelerate)
import Accelerate
#endif
#if os(Android)
import Android
private final class CounterLock {
    private var mutex = pthread_mutex_t()
    init() { pthread_mutex_init(&mutex, nil) }
    deinit { pthread_mutex_destroy(&mutex) }
    func lock() { pthread_mutex_lock(&mutex) }
    func unlock() { pthread_mutex_unlock(&mutex) }
}
#elseif os(WASI)
private final class CounterLock {
    func lock() {}
    func unlock() {}
}
#else
import Foundation
private typealias CounterLock = NSLock
#endif

/// Counts finished chunks across the worker pool and reports the fraction.
/// A lock rather than an actor so a worker never suspends to report.
private final class ChunkCounter: @unchecked Sendable {
    private let lock = CounterLock()
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

    /// How many independent chunks one `run` consumes, and in which layout.
    ///
    /// The Core ML export is ANE-shaped: planar `[B, C, F, T]` tensors with a
    /// fixed batch of four windows (`spec (4,2,481,200)`,
    /// `feat_erb (4,1,32,200)`, `feat_spec (4,2,96,200)`). Every other runtime
    /// (LiteRT/ONNX/JS host) keeps the original DFN3 layout: one window per
    /// run, interleaved `[1, 1, T, F, 2]`.
    #if canImport(CoreML)
    static let batchSize = 4
    #else
    static let batchSize = 1
    #endif

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
    /// Wall time in each stage of one `enhance` call, for
    /// ``Clear/PhaseTimings``. Seconds.
    struct StageTimings: Sendable {
        var stftForward = 0.0
        var computeFeatures = 0.0
        var modelPredict = 0.0
        var stftInverse = 0.0

        static func += (lhs: inout StageTimings, rhs: StageTimings) {
            lhs.stftForward += rhs.stftForward
            lhs.computeFeatures += rhs.computeFeatures
            lhs.modelPredict += rhs.modelPredict
            lhs.stftInverse += rhs.stftInverse
        }
    }

    /// Seconds since `start`, on the monotonic clock.
    private static func since(_ start: ContinuousClock.Instant) -> Double {
        let c = start.duration(to: .now).components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }

    func enhance(_ samples: [Float],
                 timings: UnsafeMutablePointer<StageTimings>? = nil,
                 onAnalysis: (@Sendable (Double) -> Void)? = nil,
                 onChunk: (@Sendable (Double) -> Void)? = nil) async throws -> [Float] {
        guard !samples.isEmpty, !sessions.isEmpty else { return samples }
        // Sanitize, tail-pad, and lay in the STFT prepad in a single buffer.
        // Doing these as three passes cost three full-signal copies, and at
        // 48 kHz mono each one is 363 MB for a 33-minute file.
        let padded = Self.prepareInput(samples)
        var mark = ContinuousClock.now
        let (real, imag, nFrames) = stft.forward(prePadded: padded)
        timings?.pointee.stftForward += Self.since(mark)
        guard nFrames > 0 else { return sanitize(samples) }
        onAnalysis?(0.5)

        mark = .now
        let (featErb, featSpecReal, featSpecImag) =
            ClearFeatures.compute(real: real, imag: imag, nFrames: nFrames)
        timings?.pointee.computeFeatures += Self.since(mark)
        onAnalysis?(1)

        let count = real.count
        let outRe = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let outIm = UnsafeMutablePointer<Float>.allocate(capacity: count)
        outRe.initialize(repeating: 0, count: count); outIm.initialize(repeating: 0, count: count)
        defer { outRe.deinitialize(count: count); outRe.deallocate(); outIm.deinitialize(count: count); outIm.deallocate() }

        let nChunks = (nFrames + chunkLen - 1) / chunkLen
        let batch = Self.batchSize
        let nGroups = (nChunks + batch - 1) / batch
        let workers = max(1, min(sessions.count, nGroups))
        let chunkLen = self.chunkLen
        // Each worker owns one session and a strided set of chunks; output
        // ranges are disjoint per chunk, so the shared buffers need no locking.
        let box = Unchecked((outRe, outIm, sessions, featErb, featSpecReal, featSpecImag, real, imag))
        let completed = ChunkCounter(total: nChunks, report: onChunk)
        mark = .now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for w in 0..<workers {
                group.addTask {
                    let (outRe, outIm, sessions, fe, fsr, fsi, sr, si) = box.value
                    let session = sessions[w]
                    var g = w
                    while g < nGroups {
                        let firstChunk = g * batch
                        let chunks = min(batch, nChunks - firstChunk)
                        try await Self.runGroup(session: session, firstChunk: firstChunk, chunks: chunks,
                                                nFrames: nFrames, chunkLen: chunkLen,
                                                featErb: fe, featSpecReal: fsr, featSpecImag: fsi,
                                                specReal: sr, specImag: si, outRe: outRe, outIm: outIm)
                        for _ in 0..<chunks { completed.finishOne() }
                        g += workers
                    }
                }
            }
            try await group.waitForAll()
        }
        // Wall time across the whole pool, not summed CPU: the workers run
        // concurrently, so this is what the caller actually waited.
        timings?.pointee.modelPredict += Self.since(mark)

        // Synthesize straight from the scratch buffers. Copying them into
        // `Array`s first held a second pair of spectrogram planes (726 MB at 33
        // minutes) while the originals were still live until the `defer`.
        mark = .now
        var enhanced = stft.inverse(real: outRe, imag: outIm, nFrames: nFrames)
        timings?.pointee.stftInverse += Self.since(mark)
        if enhanced.count > samples.count { enhanced.removeLast(enhanced.count - samples.count) }
        return enhanced
    }

    /// Run one group of `chunks` consecutive windows (`batchSize` of them at
    /// most) through `session` and scatter the result into the output planes.
    private static func runGroup(session: any InferenceSession, firstChunk: Int, chunks: Int,
                                 nFrames: Int, chunkLen: Int,
                                 featErb: [Float], featSpecReal: [Float], featSpecImag: [Float],
                                 specReal: [Float], specImag: [Float],
                                 outRe: UnsafeMutablePointer<Float>, outIm: UnsafeMutablePointer<Float>) async throws {
        #if canImport(CoreML)
        try await runPlanarBatch(session: session, firstChunk: firstChunk, chunks: chunks,
                                 nFrames: nFrames, chunkLen: chunkLen,
                                 featErb: featErb, featSpecReal: featSpecReal, featSpecImag: featSpecImag,
                                 specReal: specReal, specImag: specImag, outRe: outRe, outIm: outIm)
        #else
        let start = firstChunk * chunkLen
        try await runChunk(session: session, start: start, end: min(start + chunkLen, nFrames),
                           nFrames: nFrames, chunkLen: chunkLen,
                           featErb: featErb, featSpecReal: featSpecReal, featSpecImag: featSpecImag,
                           specReal: specReal, specImag: specImag, outRe: outRe, outIm: outIm)
        #endif
    }

    /// The original DFN3 layout: one window per run, interleaved complex.
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

    #if canImport(CoreML)
    /// The Core ML export's layout: a fixed batch of `batchSize` independent
    /// windows as planar `[B, C, F, T]` tensors (frequency-major, time last),
    /// which is what the ANE program declares. Unused batch elements are left
    /// zero and their outputs ignored.
    private static func runPlanarBatch(session: any InferenceSession, firstChunk: Int, chunks: Int,
                                       nFrames: Int, chunkLen: Int,
                                       featErb: [Float], featSpecReal: [Float], featSpecImag: [Float],
                                       specReal: [Float], specImag: [Float],
                                       outRe: UnsafeMutablePointer<Float>, outIm: UnsafeMutablePointer<Float>) async throws {
        let T = chunkLen, B = batchSize
        let nFreq = ClearDSP.nFreq, nErb = ClearDSP.nErb, nDf = ClearDSP.nDf
        let look = ClearDSP.convLookahead

        var specBuf = [Float](repeating: 0, count: B * 2 * nFreq * T)
        var erbBuf = [Float](repeating: 0, count: B * nErb * T)
        var featSpecBuf = [Float](repeating: 0, count: B * 2 * nDf * T)

        for b in 0..<chunks {
            let start = (firstChunk + b) * T
            // Features are read `convLookahead` frames ahead of the window; the
            // spectrum is read at the window itself. Both clamp at the tail.
            let tEnd = min(T, nFrames - start - look)
            let sEnd = min(T, nFrames - start)
            if tEnd > 0 {
                toPlanar(featErb, srcFrame: start + look, frames: tEnd, cols: nErb,
                         into: &erbBuf, planeOffset: b * nErb * T, T: T)
                toPlanar(featSpecReal, srcFrame: start + look, frames: tEnd, cols: nDf,
                         into: &featSpecBuf, planeOffset: (b * 2) * nDf * T, T: T)
                toPlanar(featSpecImag, srcFrame: start + look, frames: tEnd, cols: nDf,
                         into: &featSpecBuf, planeOffset: (b * 2 + 1) * nDf * T, T: T)
            }
            if sEnd > 0 {
                toPlanar(specReal, srcFrame: start, frames: sEnd, cols: nFreq,
                         into: &specBuf, planeOffset: (b * 2) * nFreq * T, T: T)
                toPlanar(specImag, srcFrame: start, frames: sEnd, cols: nFreq,
                         into: &specBuf, planeOffset: (b * 2 + 1) * nFreq * T, T: T)
            }
        }

        let outputs = try await session.run(
            inputs: [
                "spec": Tensor(float32: specBuf, shape: [B, 2, nFreq, T]),
                "feat_erb": Tensor(float32: erbBuf, shape: [B, 1, nErb, T]),
                "feat_spec": Tensor(float32: featSpecBuf, shape: [B, 2, nDf, T]),
            ],
            outputs: ["spec_enhanced"])
        guard let enh = outputs.first?.float32Values, enh.count >= B * 2 * nFreq * T else {
            throw ClearError.inferenceFailed("spec_enhanced missing or wrong size")
        }

        for b in 0..<chunks {
            let start = (firstChunk + b) * T
            let valid = min(T, nFrames - start)
            guard valid > 0 else { continue }
            fromPlanar(enh, planeOffset: (b * 2) * nFreq * T, cols: nFreq, T: T,
                       frames: valid, into: outRe + start * nFreq)
            fromPlanar(enh, planeOffset: (b * 2 + 1) * nFreq * T, cols: nFreq, T: T,
                       frames: valid, into: outIm + start * nFreq)
        }
    }

    /// Frame-major source (`[frame][cols]`, starting at `srcFrame`) into one
    /// `[cols][T]` plane of `dst` at `planeOffset`. A full window transposes
    /// straight into place; a short tail window transposes into scratch and
    /// then copies the columns it has, leaving the rest zero.
    private static func toPlanar(_ src: [Float], srcFrame: Int, frames: Int, cols: Int,
                                 into dst: inout [Float], planeOffset: Int, T: Int) {
        src.withUnsafeBufferPointer { sp in
            let s = sp.baseAddress! + srcFrame * cols
            dst.withUnsafeMutableBufferPointer { dp in
                let d = dp.baseAddress! + planeOffset
                if frames == T {
                    vDSP_mtrans(s, 1, d, 1, vDSP_Length(cols), vDSP_Length(frames))
                } else {
                    var scratch = [Float](repeating: 0, count: cols * frames)
                    scratch.withUnsafeMutableBufferPointer { tp in
                        vDSP_mtrans(s, 1, tp.baseAddress!, 1, vDSP_Length(cols), vDSP_Length(frames))
                        vDSP_mmov(tp.baseAddress!, d, vDSP_Length(frames), vDSP_Length(cols),
                                  vDSP_Length(frames), vDSP_Length(T))
                    }
                }
            }
        }
    }

    /// The inverse: one `[cols][T]` plane of `src` back to `frames` rows of a
    /// frame-major destination.
    private static func fromPlanar(_ src: [Float], planeOffset: Int, cols: Int, T: Int,
                                   frames: Int, into dst: UnsafeMutablePointer<Float>) {
        src.withUnsafeBufferPointer { sp in
            let s = sp.baseAddress! + planeOffset
            if frames == T {
                vDSP_mtrans(s, 1, dst, 1, vDSP_Length(frames), vDSP_Length(cols))
            } else {
                var scratch = [Float](repeating: 0, count: cols * frames)
                scratch.withUnsafeMutableBufferPointer { tp in
                    vDSP_mmov(s, tp.baseAddress!, vDSP_Length(frames), vDSP_Length(cols),
                              vDSP_Length(T), vDSP_Length(frames))
                    vDSP_mtrans(tp.baseAddress!, 1, dst, 1, vDSP_Length(frames), vDSP_Length(cols))
                }
            }
        }
    }
    #endif

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

    /// One allocation carrying, in order: the `fftSize - hopSize` analysis
    /// prepad, the sanitized signal, and enough tail zeros to reach a whole
    /// number of windows. Same layout the old
    /// `stft.forward(padToWindowMultiple(sanitize(x)))` chain produced, without
    /// the intermediate copies.
    private static func prepareInput(_ samples: [Float]) -> [Float] {
        let hop = ClearDSP.hopSize, fft = ClearDSP.fftSize
        let prePad = fft - hop
        let windowed = max(fft, ((samples.count + hop - 1) / hop) * hop + fft)
        var padded = [Float](repeating: 0, count: prePad + max(windowed, samples.count))
        padded.withUnsafeMutableBufferPointer { dp in
            let body = dp.baseAddress! + prePad
            samples.withUnsafeBufferPointer { sp in
                if let s = sp.baseAddress { body.update(from: s, count: samples.count) }
            }
            for i in 0..<samples.count where !body[i].isFinite { body[i] = 0 }
        }
        return padded
    }
}
