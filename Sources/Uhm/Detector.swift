// The frame-level detector: sliding 30 s windows over 16 kHz mono samples,
// one softmax per 20 ms frame from the model, then threshold + run-merging
// into (start, end) spans. Platform-neutral: the model runs behind DesertAnt's
// `InferenceSession` (Core ML on Apple today), and audio decode happens in
// `Uhm.swift` via AudioIO, so nothing here touches a file or a framework.

import DesertAnt

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
        var minFrameProb: Double      // per-frame threshold for "is filler"
        var minDurationSec: Double    // discard runs shorter than this
        var mergeGapSec: Double       // merge adjacent runs within this gap

        static let `default` = Config(
            sampleRate: 16_000,
            maxWindowSec: 30.0,
            hopSec: 25.0,                // 5s overlap between windows
            frameHopSamples: 320,
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

    let config: Config
    private let session: any InferenceSession
    private let maxSamples: Int

    init(session: any InferenceSession, config: Config = .default) {
        var c = config
        if let s = environmentVariable("UHM_FRAME_MIN_PROB"), let v = Double(s) {
            c.minFrameProb = v
        }
        self.session = session
        self.maxSamples = Int(c.maxWindowSec * c.sampleRate)
        self.config = c
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
        for (index, range) in winOffsets.enumerated() {
            try Task.checkCancellation()
            let prepStart = ContinuousClock.now
            let input = normalizedWindow(samples, start: range.start, end: range.end)
            let tensor = Tensor(float32: input, shape: [1, maxSamples])
            t.prepSec += Self.elapsed(since: prepStart)
            let inferenceStart = ContinuousClock.now
            let outputs = try await session.run(
                inputs: [Self.inputName: tensor], outputs: [Self.outputName])
            t.inferenceSec += Self.elapsed(since: inferenceStart)
            let probs = Self.fillerProbs(outputs.first)
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
            progressHandler?(min(1.0, Double(index + 1) / Double(winOffsets.count)))
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

    /// Per-frame filler probability from the model's `(1, T, C)` softmax:
    /// `1 - p_not_filler` (class 0). The session backends already deliver
    /// dense float32, so no stride/precision handling is needed here.
    private static func fillerProbs(_ tensor: Tensor?) -> [Float] {
        guard let tensor, let values = tensor.float32Values else { return [] }
        let shape = tensor.shape
        guard shape.count >= 3 else { return values }
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
