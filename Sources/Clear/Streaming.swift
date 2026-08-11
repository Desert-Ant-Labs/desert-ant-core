#if canImport(AVFoundation) && canImport(Foundation)
import AVFoundation
import AudioDSP
import AudioIO
import DesertAnt
import Foundation

// File-to-file enhancement in bounded memory.
//
// The in-memory pipeline (`Clear.enhance(samples:)`) holds the signal, its
// spectrogram, and the enhanced result at once - roughly 383 MB per 5 minutes
// at 48 kHz, so a 33-minute recording peaks in the gigabytes and an hour is
// simply not possible on a phone. This path keeps peak flat instead: it works
// on 20-second windows and streams both ends.
//
// Two things make windowing safe:
//
//   * The model runs on independent 200-frame chunks, so cutting the signal
//     into windows changes nothing about inference itself.
//   * The ERB/DF front end carries a running mean (EMA, tau = 1 s). That state
//     cannot be cut, so each window is fed 3 s of the previous window's audio
//     as warmup and that prefix is discarded from the output. At tau = 1 s,
//     3 s is ~95% convergence, so the seam is inaudible - but it does mean the
//     output is not bit-identical to the whole-file path. Tests assert SNR, not
//     equality.
//
// Mastering needs the integrated loudness of the *enhanced* signal, which is
// only known once the last window is done. Rather than predict it from the
// input (what the previous SDK did, via a calibrated attenuation constant) the
// enhanced audio goes to a float32 scratch file while a streaming meter runs,
// then a second, cheap pass applies the gain and encodes. No model work is
// repeated.

extension Clear {
    /// Samples spanned by one model chunk: 200 frames at a 480-sample hop, so
    /// exactly 2 s at 48 kHz.
    ///
    /// Both the window and the warmup must be whole multiples of this. The
    /// model runs on a fixed 200-frame grid, and a window whose start is not on
    /// that grid shifts every chunk boundary inside it, which moves the
    /// per-chunk edge effects and audibly changes the output. Measured against
    /// the in-memory path: a 4 s warmup (2 chunks) agrees at ~43 dB SNR, while
    /// 3 s (1.5 chunks) collapses to ~12 dB. Length past the first couple of
    /// chunks buys nothing - 4 s, 6 s and 10 s all land at ~43 dB - so this is
    /// an alignment constraint, not a convergence one.
    private static var chunkSamples: Int { 200 * ClearDSP.hopSize }

    /// Window of new audio per iteration. 10 chunks.
    private static var windowFrames: Int { 10 * chunkSamples }

    /// Audio replayed from the previous window so the feature EMA (tau = 1 s)
    /// reconverges before the samples we keep. 2 chunks = 4 s, which is both
    /// grid-aligned and ~98% converged.
    private static var warmupFrames: Int { 2 * chunkSamples }

    func enhanceStreaming(path: String, to outputPath: String,
                          options: Options,
                          progress: ProgressHandler?) async throws -> Result {
        if let progress {
            progress(Progress(phase: .loadingModel, fraction: 0))
            try await model.download { progress(Progress(phase: .loadingModel, fraction: $0)) }
        }
        let assets = try await model.value()
        let start = ContinuousClock.now
        let sampleRate = ClearDSP.sampleRate

        let reader = try AudioIO.StreamingReader(path: path, sampleRate: sampleRate)
        let enhancer = ClearEnhancer(sessions: assets.sessions)
        let meter = Loudness.StreamingMeter(sampleRate: sampleRate)

        // The front end is per window and quick; report it once so the phase
        // sequence still reads analyzing -> enhancing for a caller's UI.
        progress?(Progress(phase: .analyzing, fraction: 1))
        progress?(Progress(phase: .enhancing, fraction: 0))

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clear-stream-\(UUID().uuidString).f32")
        guard FileManager.default.createFile(atPath: scratch.path, contents: nil) else {
            throw ClearError.inferenceFailed("cannot create a scratch file")
        }
        defer { try? FileManager.default.removeItem(at: scratch) }

        let strength = Float(options.strength.value)
        let blend = strength < 0.999
        var totalFrames = 0

        // Expected output length, for progress. The reader reports position at
        // the source rate, so convert.
        let expectedFrames = reader.sourceSampleRate > 0
            ? Double(reader.totalSourceFrames) * (sampleRate / reader.sourceSampleRate)
            : 0

        do {
            let scratchHandle = try FileHandle(forWritingTo: scratch)
            defer { try? scratchHandle.close() }

            var previousTail = [Float]()
            while true {
                try Task.checkCancellation()
                guard let window = try reader.next(maxFrames: Self.windowFrames), !window.isEmpty else { break }

                // Warmup prefix + this window. The prefix is real audio the
                // model has already seen; it only exists to converge the EMA.
                var input = previousTail
                input.append(contentsOf: window)
                let prefix = previousTail.count

                let enhanced = try await enhancer.enhance(input)
                guard enhanced.count >= prefix else {
                    throw ClearError.inferenceFailed("window shorter than its warmup prefix")
                }
                var useful = Array(enhanced[prefix...])
                if useful.count > window.count { useful.removeLast(useful.count - window.count) }

                if blend {
                    let n = min(useful.count, window.count)
                    for i in 0..<n { useful[i] = strength * useful[i] + (1 - strength) * window[i] }
                }

                meter?.consume(useful)
                totalFrames += useful.count
                try useful.withUnsafeBufferPointer { bp in
                    try scratchHandle.write(contentsOf: Data(bytes: bp.baseAddress!,
                                                             count: bp.count * MemoryLayout<Float>.size))
                }

                previousTail = window.count > Self.warmupFrames
                    ? Array(window[(window.count - Self.warmupFrames)...])
                    : window

                if let progress, expectedFrames > 0 {
                    progress(Progress(phase: .enhancing,
                                      fraction: min(1, Double(totalFrames) / expectedFrames)))
                }
            }
        }

        // Mastering: one gain for the whole file, from the enhanced signal's own
        // loudness, matching what the in-memory path computes. The peak ceiling
        // is the limiter's job in the second pass, not this gain's - backing the
        // whole file off to fit its loudest transient would miss the target.
        var measured: Double? = nil
        var gain: Float = 1
        let mastering = options.mastering
        if mastering.enabled, let meter, let lufs = meter.finalize() {
            measured = lufs
            var gainDB = mastering.integratedLUFS - lufs
            if gainDB > mastering.maxLoudnessGainDB { gainDB = mastering.maxLoudnessGainDB }
            gain = Float(pow(10, gainDB / 20))
        }

        // Second pass: scratch -> encoder, applying the gain. No model, no DSP.
        let writer = try AudioIO.StreamingWriter(to: outputPath, sampleRate: Int(sampleRate), channels: 1)
        defer { writer.finish() }
        let readHandle = try FileHandle(forReadingFrom: scratch)
        defer { try? readHandle.close() }
        let blockBytes = (1 << 16) * MemoryLayout<Float>.size
        let applyGain = mastering.enabled
        // Carries the gain envelope and its look-ahead tail across blocks, so a
        // file mastered here matches the same audio mastered in memory.
        let limiter = applyGain
            ? Limiter.Streaming(ceilingDBTP: mastering.truePeakDBTP,
                                sampleRate: sampleRate, channels: 1)
            : nil
        let truePeakMeter = applyGain ? Limiter.TruePeakMeter() : nil
        while true {
            try Task.checkCancellation()
            let data = try readHandle.read(upToCount: blockBytes) ?? Data()
            if data.isEmpty { break }
            var block = data.withUnsafeBytes { raw -> [Float] in
                Array(raw.bindMemory(to: Float.self))
            }
            if let limiter {
                for i in 0..<block.count { block[i] *= gain }
                block = limiter.process([block])[0]
            }
            truePeakMeter?.consume(block)
            try writer.write(block)
        }
        if let limiter {
            let tail = limiter.flush()[0]
            if !tail.isEmpty {
                truePeakMeter?.consume(tail)
                try writer.write(tail)
            }
        }
        writer.finish()

        progress?(Progress(phase: .enhancing, fraction: 1))
        return Result(samples: [], sampleRate: sampleRate,
                      durationSec: Double(totalFrames) / sampleRate,
                      processingSec: elapsedSeconds(since: start), measuredLUFS: measured,
                      measuredTruePeakDBFS: truePeakMeter?.dBFS,
                      modelVariant: assets.variant)
    }
}
#endif
