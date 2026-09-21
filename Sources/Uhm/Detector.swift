// The frame-level detector: sliding 30 s windows over 16 kHz mono samples,
// one softmax per 20 ms frame from the model, then threshold + run-merging
// into (start, end) spans. Platform-neutral: the model runs behind DesertAnt's
// `InferenceSession` (Core ML on Apple today), and audio decode happens in
// `Uhm.swift` via AudioIO, so nothing here touches a file or a framework.

import DesertAnt

#if os(Android)
import Android
private final class WindowLock {
    private var mutex = pthread_mutex_t()
    init() { pthread_mutex_init(&mutex, nil) }
    deinit { pthread_mutex_destroy(&mutex) }
    func lock() { pthread_mutex_lock(&mutex) }
    func unlock() { pthread_mutex_unlock(&mutex) }
}
#elseif os(WASI)
private final class WindowLock {
    func lock() {}
    func unlock() {}
}
#else
import Foundation
private typealias WindowLock = NSLock
#endif

/// One slot per window, written by whichever task ran it.
///
/// The windows complete in whatever order the backend finishes them, so each
/// writes its own index and the reduction reads them back in order afterwards:
/// the frame probabilities do not depend on how widely the run was spread.
/// A lock rather than an actor so a task never suspends to store a result.
private final class WindowResults: @unchecked Sendable {
    private let lock = WindowLock()
    private var slots: [[Float]]

    init(count: Int) { slots = Array(repeating: [], count: count) }

    func set(_ index: Int, _ probs: [Float]) {
        lock.lock()
        slots[index] = probs
        lock.unlock()
    }

    func get(_ index: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return slots[index]
    }
}

/// Counts finished windows and reports the fraction, since "window n of m"
/// stops being the same thing as "m windows done" once they overlap.
private final class ProgressCounter: @unchecked Sendable {
    private let lock = WindowLock()
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

/// Frame-level filler detector. Wraps an inference session that emits a
/// per-frame softmax (20 ms frames) over filler classes; this type thresholds
/// and merges consecutive positive frames into `Filler` spans. Pair with
/// `FillerTypeClassifier` (Apple) to assign a `Uhm.FillerType`.
struct FillerDetector: Sendable {

    // MARK: - Configuration

    struct Config: Sendable {
        var sampleRate: Double
        var maxWindowSec: Double      // model's fixed input length
        var hopSec: Double            // sliding window hop between successive model calls
        var frameHopSamples: Int      // conv stem hop (320 = 20ms @ 16kHz)
        var receptiveFieldSamples: Int // conv stem receptive field (400 = 25ms)
        var minFrameProb: Double      // per-frame threshold for "is filler"
        var minDurationSec: Double    // discard runs shorter than this
        var mergeGapSec: Double       // merge adjacent runs within this gap

        static let `default` = Config(
            sampleRate: 16_000,
            maxWindowSec: 30.0,
            hopSec: 25.0,                // 5s overlap between windows
            frameHopSamples: 320,
            receptiveFieldSamples: 400,
            minFrameProb: 0.5,
            minDurationSec: 0.10,
            mergeGapSec: 0.10
        )
    }

    /// Bucketed wall-time captured during a single `detect()` call. Exposed via
    /// the `timingsHandler` for diagnostic / bench callers that want to see
    /// where inference time is going.
    struct Timings: Sendable {
        /// Total session-run wall time across every window. Everything
        /// accelerator-side lives here.
        var inferenceSec: Double
        /// Per-window normalize + input build.
        var prepSec: Double
        /// Frame-prob threshold + run merging.
        var groupSec: Double

        init(inferenceSec: Double = 0, prepSec: Double = 0, groupSec: Double = 0) {
            self.inferenceSec = inferenceSec
            self.prepSec = prepSec
            self.groupSec = groupSec
        }
    }

    // The export's tensor names (`models/convert_to_onnx.py` /
    // `convert_to_coreml.py` in the model repo fix both).
    private static let inputName = "audio"
    private static let outputName = "probs"

    /// How the model wants its window, read off the artifact rather than assumed.
    ///
    /// The Neural Engine caps every tensor axis at 16384, so an ANE-resident
    /// export cannot take a 480000-sample window as one row: it takes the window
    /// pre-cut into overlapping tiles. Which one we have is a property of the
    /// file, so it is detected from the declared input width instead of being a
    /// flag someone has to keep in step with the download.
    enum Layout: Sendable, Equatable {
        /// One row of `maxWindowSec` samples: `(1, maxSamples)`.
        case window
        /// `(tiles, 1, 1, tileSamples)`, each tile overlapping the next by the
        /// stem's receptive-field halo so the frames it produces are identical
        /// to the ones the whole-window model produces.
        case tiles(count: Int, samples: Int, stride: Int)
    }

    let config: Config
    let layout: Layout
    private let session: any InferenceSession
    private let maxSamples: Int

    init(session: any InferenceSession, config: Config = .default) {
        var c = config
        if let s = environmentVariable("UHM_FRAME_MIN_PROB"), let v = Double(s) {
            c.minFrameProb = v
        }
        self.session = session
        let maxSamples = Int(c.maxWindowSec * c.sampleRate)
        self.maxSamples = maxSamples
        self.config = c
        self.layout = Self.layout(for: session, maxSamples: maxSamples, config: c)
    }

    /// A declared input width below the full window means a tiled export.
    /// Everything else about the tiling follows from that one number plus the
    /// stem's geometry, so there is nothing to keep in sync by hand.
    private static func layout(for session: any InferenceSession,
                              maxSamples: Int, config: Config) -> Layout {
        guard let width = session.inputWidth(inputName), width > 0, width < maxSamples
        else { return .window }
        // The halo is what a tile needs beyond its own frames for the conv stem
        // to see the same context the whole-window model sees.
        let halo = config.receptiveFieldSamples - config.frameHopSamples
        let stride = width - halo
        guard stride > 0 else { return .window }
        let count = (maxSamples + stride - 1) / stride
        return .tiles(count: count, samples: width, stride: stride)
    }

    // MARK: - Detection

    /// Detect filler spans in mono `samples` (at `config.sampleRate`). Runs
    /// sliding windows of `maxWindowSec` with `hopSec` hop and averages
    /// overlapping frame probs. Honours `Task.cancel()` between windows.
    ///
    /// Passing an optional `timingsHandler` opts into a per-phase wall-time
    /// breakdown; the timer overhead is negligible and the handler runs
    /// synchronously before returning.
    func detect(
        samples: [Float],
        progressHandler: (@Sendable (Double) -> Void)? = nil,
        timingsHandler: ((Timings) -> Void)? = nil
    ) async throws -> [Filler] {
        var t = Timings()
        // Early bail if the caller already cancelled before we started.
        try Task.checkCancellation()
        guard !samples.isEmpty else {
            timingsHandler?(t)
            return []
        }

        let stepSamples = Int(config.hopSec * config.sampleRate)
        let totalFrames = (samples.count + config.frameHopSamples - 1) / config.frameHopSamples
        var sumProbs = [Float](repeating: 0, count: totalFrames)
        var counts = [Float](repeating: 0, count: totalFrames)

        var winOffsets: [(start: Int, end: Int)] = []
        var winStart = 0
        while winStart < samples.count {
            let end = min(samples.count, winStart + maxSamples)
            winOffsets.append((winStart, end))
            if end == samples.count { break }
            winStart += stepSamples
        }

        progressHandler?(0)
        // The windows do not depend on each other, so how many run at once is a
        // property of the backend rather than of this loop: `ParallelRuns` keeps
        // as many in flight as the session it is given can take. One window at a
        // time leaves a two-engine part running on one of them (measured on an
        // M3 Ultra: 121 ms per window alone, 38 ms with four in flight; on
        // single-engine chips the same depth changes nothing, because one window
        // already fills the engine).
        //
        // Each window writes its own slot and the reduction happens after, so
        // the result does not depend on completion order.
        let windows = winOffsets   // immutable for the concurrent reads below
        let windowResults = WindowResults(count: windows.count)
        let progress = ProgressCounter(total: windows.count, report: progressHandler)
        let parallelStart = ContinuousClock.now
        try await ParallelRuns.run(count: windows.count, sessions: [session]) { index, session in
            try Task.checkCancellation()
            let range = windows[index]
            // Prep sits inside the task so it overlaps the runs already in
            // flight instead of stalling them between windows.
            let input = self.normalizedWindow(samples, start: range.start, end: range.end)
            let tensor = Self.tensor(for: input, layout: self.layout, maxSamples: self.maxSamples)
            let outputs = try await session.run(
                inputs: [Self.inputName: tensor], outputs: [Self.outputName])
            windowResults.set(index, Self.fillerProbs(outputs.first))
            progress.finishOne()
        }
        // Wall, not summed CPU: the windows overlap, so what the caller waited
        // for is the span of the whole group. Prep is inside it for the same
        // reason - it no longer happens anywhere a clock could separate it.
        t.inferenceSec = Self.elapsed(since: parallelStart)

        for (index, range) in winOffsets.enumerated() {
            let probs = windowResults.get(index)
            let frameOffset = range.start / config.frameHopSamples
            let usableFrames = (range.end - range.start + config.frameHopSamples - 1)
                / config.frameHopSamples
            for k in 0..<min(usableFrames, probs.count) {
                let g = frameOffset + k
                if g < totalFrames {
                    sumProbs[g] += probs[k]
                    counts[g] += 1
                }
            }
        }

        // Average overlapping windows.
        var probs = [Float](repeating: 0, count: totalFrames)
        for i in 0..<totalFrames {
            probs[i] = counts[i] > 0 ? sumProbs[i] / counts[i] : 0
        }
        let groupStart = ContinuousClock.now
        let fillers = Self.group(probs: probs, config: config)
        t.groupSec = Self.elapsed(since: groupStart)
        timingsHandler?(t)
        return fillers
    }

    // MARK: - Helpers

    /// Per-window mean/std normalize, matching the feature extractor used in
    /// training, zero-padded to the model's fixed window.
    private func normalizedWindow(_ samples: [Float], start: Int, end: Int) -> [Float] {
        var mean: Float = 0
        for i in start..<end { mean += samples[i] }
        mean /= Float(end - start)
        var sumSq: Float = 0
        for i in start..<end { sumSq += (samples[i] - mean) * (samples[i] - mean) }
        let std = (sumSq / Float(max(1, end - start - 1))).squareRoot() + 1e-7
        let invStd = 1 / std

        var window = [Float](repeating: 0, count: maxSamples)
        for k in 0..<(end - start) { window[k] = (samples[start + k] - mean) * invStd }
        return window
    }

    /// Lay a normalized window out the way this model's graph expects.
    ///
    /// Tiles overlap by the halo and the tail is zero-padded, which is exactly
    /// what the whole-window model does at the end of a short final window.
    static func tensor(for window: [Float], layout: Layout, maxSamples: Int) -> Tensor {
        switch layout {
        case .window:
            return Tensor(float32: window, shape: [1, maxSamples])
        case let .tiles(count, samples, stride):
            var tiled = [Float](repeating: 0, count: count * samples)
            for tile in 0..<count {
                let start = tile * stride
                guard start < window.count else { break }
                let available = min(samples, window.count - start)
                for k in 0..<available {
                    tiled[tile * samples + k] = window[start + k]
                }
            }
            return Tensor(float32: tiled, shape: [count, 1, 1, samples])
        }
    }

    /// Per-frame filler probability, `1 - p_not_filler` (class 0), from either
    /// output layout: `(1, T, C)` from the whole-window export, or BC1S
    /// `(1, C, 1, T)` from the ANE-resident one, where the class axis has to
    /// come second so the sequence stays in the last (DMA-aligned) position.
    /// The session backends deliver dense float32, so no stride handling here.
    static func fillerProbs(_ tensor: Tensor?) -> [Float] {
        guard let tensor, let values = tensor.float32Values else { return [] }
        let shape = tensor.shape
        guard shape.count >= 3 else { return values }
        if shape.count == 4 && shape[2] == 1 {
            // (1, C, 1, T): class 0 occupies the first T values.
            let t = shape[3]
            guard values.count >= t else { return [] }
            return (0..<t).map { 1.0 - values[$0] }
        }
        let t = shape[shape.count - 2]
        let c = shape[shape.count - 1]
        var result = [Float]()
        result.reserveCapacity(t)
        for frame in 0..<t {
            result.append(1.0 - values[frame * c])
        }
        return result
    }

    /// Threshold frame probs and merge adjacent runs into spans.
    static func group(probs: [Float], config: Config) -> [Filler] {
        let threshold = Float(config.minFrameProb)
        let frameSec = Double(config.frameHopSamples) / config.sampleRate
        var fillers: [Filler] = []
        var i = 0
        while i < probs.count {
            if probs[i] < threshold { i += 1; continue }
            var j = i
            var sum: Float = 0
            while j < probs.count && probs[j] >= threshold {
                sum += probs[j]
                j += 1
            }
            let startSec = Double(i) * frameSec
            let endSec = Double(j) * frameSec
            let avgConf = Double(sum / Float(j - i))
            if let last = fillers.last, startSec - last.end <= config.mergeGapSec {
                fillers[fillers.count - 1] = Filler(
                    label: "filler",
                    start: last.start, end: endSec,
                    confidence: max(last.confidence, avgConf))
            } else if endSec - startSec >= config.minDurationSec {
                fillers.append(Filler(
                    label: "filler",
                    start: startSec, end: endSec,
                    confidence: avgConf))
            }
            i = j
        }
        return fillers
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let components = start.duration(to: .now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
