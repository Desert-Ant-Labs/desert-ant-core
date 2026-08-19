#if canImport(CoreML)
import CoreML
import Foundation

/// The recognition pipeline: mel, encoder, and a lane-batched transducer decode.
///
/// Not `Sendable` and not reentrant: it owns preallocated buffers that every
/// call mutates. `Scribe` serialises access through an actor.
final class Pipeline {
    private let assets: Assets
    private var configuration: Configuration { assets.configuration }

    // Aligning boundaries to silence costs about 13% of throughput -- 292 to 255
    // RTFx on ten minutes of speech, 239 to 208 over half an hour -- which is
    // the 1.12x extra windows it creates and nothing else. The scan itself does
    // not show up. Measured back to back in one binary via SCRIBE_FIXED_WINDOWS.

    /// Windows end at the quietest point in this much audio before the nominal
    /// boundary, so a window rarely stops in the middle of a word.
    private static let boundarySearch = 3.0
    /// Energy is measured over frames this long when looking for that point.
    private static let boundaryFrame = 0.02

    /// How many windows are encoded before their decode runs. Bounds peak memory
    /// (each window's encoder output is ~240 KB) and gives progress somewhere to
    /// be reported from, while staying long enough that the decoder's lanes stay
    /// full for all but the last group.
    private static let batchWindows = 64

    private let rows: Buffer
    private let melOut: Buffer
    private let keyBias: Buffer
    private let padMask: Buffer
    private let encOut: Buffer
    private let embed: Buffer
    private let hIn: Buffer
    private let cIn: Buffer
    private let encStep: Buffer
    private let logitsOut: Buffer
    private let hOut: Buffer
    private let cOut: Buffer

    private let melProvider: MLDictionaryFeatureProvider
    private let encoderProvider: MLDictionaryFeatureProvider
    private let stepProvider: MLDictionaryFeatureProvider
    private let melOptions = MLPredictionOptions()
    private let encoderOptions = MLPredictionOptions()
    private let stepOptions = MLPredictionOptions()

    init(assets: Assets) throws {
        self.assets = assets
        let c = assets.configuration
        let lanes = assets.decodeLanes
        let hidden = c.predLayers * c.predHidden

        rows = try Buffer([1, c.hopLength, 1, c.nRows])
        melOut = try Buffer([1, c.nMels, 1, c.validFrames])
        keyBias = try Buffer([1, c.encFrames, 1, 1])
        padMask = try Buffer([1, 1, 1, c.encFrames])
        encOut = try Buffer([1, c.jointHidden, 1, c.encFrames])
        embed = try Buffer([lanes, c.predHidden, 1, 1])
        hIn = try Buffer([lanes, hidden, 1, 1])
        cIn = try Buffer([lanes, hidden, 1, 1])
        encStep = try Buffer([lanes, c.jointHidden, 1, c.decodeWidth])
        logitsOut = try Buffer([lanes, c.vocabSize + 1 + c.durations.count, 1, c.decodeWidth])
        hOut = try Buffer([lanes, hidden, 1, 1])
        cOut = try Buffer([lanes, hidden, 1, 1])

        // pad_mask stays all ones on purpose. Zeroing the convolution input over
        // padded frames makes those frames explode through the BatchNorm that
        // follows, until their attention scores overpower the additive mask and
        // silence the whole utterance. Masking attention alone is enough.
        padMask.ptr.update(repeating: 1, count: padMask.count)

        melProvider = try MLDictionaryFeatureProvider(dictionary: [
            "audio_rows": MLFeatureValue(multiArray: rows.array)])
        encoderProvider = try MLDictionaryFeatureProvider(dictionary: [
            "mel": MLFeatureValue(multiArray: melOut.array),
            "key_bias": MLFeatureValue(multiArray: keyBias.array),
            "pad_mask": MLFeatureValue(multiArray: padMask.array)])
        stepProvider = try MLDictionaryFeatureProvider(dictionary: [
            "embed": MLFeatureValue(multiArray: embed.array),
            "h_in": MLFeatureValue(multiArray: hIn.array),
            "c_in": MLFeatureValue(multiArray: cIn.array),
            "enc_step": MLFeatureValue(multiArray: encStep.array)])
        // Write predictions straight into our own storage instead of letting
        // Core ML allocate a result per call.
        melOptions.outputBackings = ["mel": melOut.array]
        encoderOptions.outputBackings = ["enc_proj": encOut.array]
        stepOptions.outputBackings = [
            "logits": logitsOut.array, "h_out": hOut.array, "c_out": cOut.array]
    }

    // MARK: - Frontend

    /// Lay PCM out the way the mel model expects.
    ///
    /// NeMo's featurizer runs `stft(center=True)`, so the signal is zero-padded
    /// by `nFFT / 2` on the left; without that every frame shifts by 256 samples
    /// and the transcript changes while still reading naturally. The right pad is
    /// the geometric tail `preemph^(j+1) * x[-1]` rather than zeros, which is
    /// what makes in-graph preemphasis agree with NeMo's preemphasise-then-pad
    /// order across the boundary.
    private func frame(_ window: ArraySlice<Float>) {
        rows.zero()
        let hop = configuration.hopLength
        let pad = configuration.nFFT / 2
        let total = min(configuration.nPaddedSamples, configuration.nRows * hop)
        let n = configuration.nSamples
        let base = window.startIndex
        let last: Float = window.count == n ? (window.last ?? 0) : 0
        for i in pad..<total {
            let k = i - pad
            var value: Float
            if k < n {
                value = k < window.count ? window[base + k] : 0
            } else {
                value = last == 0 ? 0 : powf(configuration.preemph, Float(k - n + 1)) * last
            }
            if value != 0 { rows.ptr[(i % hop) * configuration.nRows + i / hop] = Element(value) }
        }
    }

    /// One window of audio to encoder projections, written into `destination`.
    private func encode(window: ArraySlice<Float>, validFrames: Int,
                        into destination: UnsafeMutablePointer<Element>) throws {
        frame(window)
        _ = try assets.mel.prediction(from: melProvider, options: melOptions)
        let frames = configuration.encFrames
        let valid = max(1, min(frames, validFrames))
        keyBias.zero()
        // A short window is mostly silence. Without this the encoder attends
        // over it; -40000 is a float16-representable stand-in for -infinity.
        for i in valid..<frames { keyBias.ptr[i] = Element(-40000) }
        _ = try assets.encoder.prediction(from: encoderProvider, options: encoderOptions)
        destination.update(from: encOut.ptr, count: configuration.jointHidden * frames)
    }

    // MARK: - Decode

    /// Greedy TDT decode of several independent windows in the lanes of one call.
    ///
    /// Decoding is dispatch-bound: a call costs about the same whatever work it
    /// carries (eight times the window is 1% slower), and every emitted token
    /// forces its own dispatch because it changes the prediction state. Windows
    /// do not interact, so running several in lockstep amortises that fixed cost,
    /// and a lane that finishes takes the next pending window immediately rather
    /// than idling until the whole group is done.
    private func decode(projections: [Element], valids: [Int],
                        tokens: inout [[Int]], frames: inout [[Int]]) throws {
        let c = configuration
        let width = c.decodeWidth
        let lanes = assets.decodeLanes
        let joint = c.jointHidden
        let total = c.encFrames
        let vocab = c.vocabSize
        let blank = c.blankIdx
        let logitCount = vocab + 1 + c.durations.count
        let stride = joint * total
        let hidden = c.predLayers * c.predHidden

        var pending = 0
        var slot = [Int](repeating: -1, count: lanes)
        var position = [Int](repeating: 0, count: lanes)
        var label = [Int](repeating: blank, count: lanes)
        var emitted = [Int](repeating: 0, count: lanes)
        var limit = [Int](repeating: 0, count: lanes)
        hIn.zero(); cIn.zero(); embed.zero(); encStep.zero()

        func admit(_ lane: Int) {
            guard pending < valids.count else { slot[lane] = -1; return }
            slot[lane] = pending
            position[lane] = 0
            label[lane] = blank
            emitted[lane] = 0
            limit[lane] = max(1, min(total, valids[pending]))
            (hIn.ptr + lane * hidden).update(repeating: 0, count: hidden)
            (cIn.ptr + lane * hidden).update(repeating: 0, count: hidden)
            pending += 1
        }
        for lane in 0..<lanes { admit(lane) }

        while slot.contains(where: { $0 >= 0 }) {
            projections.withUnsafeBufferPointer { source in
                assets.embedding.withUnsafeBufferPointer { table in
                    for lane in 0..<lanes where slot[lane] >= 0 {
                        (embed.ptr + lane * c.predHidden)
                            .update(from: table.baseAddress! + label[lane] * c.predHidden,
                                    count: c.predHidden)
                        let span = min(width, limit[lane] - position[lane])
                        let base = source.baseAddress! + slot[lane] * stride
                        for channel in 0..<joint {
                            let destination = encStep.ptr + (lane * joint + channel) * width
                            destination.update(from: base + channel * total + position[lane],
                                               count: span)
                            if span < width {
                                (destination + span).update(repeating: 0, count: width - span)
                            }
                        }
                    }
                }
            }
            _ = try assets.decodeStep.prediction(from: stepProvider, options: stepOptions)

            for lane in 0..<lanes where slot[lane] >= 0 {
                let window = slot[lane]
                let span = min(width, limit[lane] - position[lane])
                let laneLogits = logitsOut.ptr + lane * logitCount * width
                var offset = 0
                var didEmit = false
                while offset < span {
                    var best = 0
                    var bestValue = Float(laneLogits[offset])
                    for k in 1...vocab {
                        let value = Float(laneLogits[k * width + offset])
                        if value > bestValue { bestValue = value; best = k }
                    }
                    var bestDuration = 0
                    var bestDurationValue = Float(laneLogits[(vocab + 1) * width + offset])
                    for k in 1..<c.durations.count {
                        let value = Float(laneLogits[(vocab + 1 + k) * width + offset])
                        if value > bestDurationValue { bestDurationValue = value; bestDuration = k }
                    }
                    let duration = c.durations[bestDuration]
                    if best != blank {
                        tokens[window].append(best)
                        frames[window].append(position[lane] + offset)
                        (hIn.ptr + lane * hidden).update(from: hOut.ptr + lane * hidden, count: hidden)
                        (cIn.ptr + lane * hidden).update(from: cOut.ptr + lane * hidden, count: hidden)
                        label[lane] = best
                        emitted[lane] += 1
                        var step = duration
                        // TDT may predict a zero duration; force progress so a
                        // lane cannot emit forever on one frame.
                        if step == 0 && emitted[lane] >= 10 { step = 1; emitted[lane] = 0 }
                        position[lane] += offset + step
                        didEmit = true
                        break
                    }
                    emitted[lane] = 0
                    offset += duration > 0 ? duration : 1
                }
                if !didEmit { position[lane] += max(offset, 1) }
                if position[lane] >= limit[lane] { admit(lane) }
            }
        }
    }

    /// Where each window should start, in samples.
    ///
    /// A fixed 15 s grid cuts wherever it lands, and the model is measurably
    /// sensitive to that: a crop beginning mid-word can decode to nothing at all
    /// or stop emitting well before its end, while the same audio at any other
    /// offset transcribes normally. That is the model's behaviour and not this
    /// export's -- float32 PyTorch reproduces it, and the encoder matches NeMo's
    /// reference to 116 dB -- so the fix is to stop handing it crops it handles
    /// badly rather than to check its output afterwards.
    ///
    /// The model was trained on utterances, which begin and end in silence, so
    /// each boundary is placed at the quietest point in the last few seconds of
    /// the window. Windows are therefore up to `nSamples` long and usually a
    /// little shorter, and each one starts where the speaker paused.
    private func boundaries(_ samples: [Float]) -> [Int] {
        let c = configuration
        let window = c.nSamples
        // A fixed grid is what this replaced. Kept switchable so the cost of
        // aligning to silence can be measured rather than estimated.
        if ProcessInfo.processInfo.environment["SCRIBE_FIXED_WINDOWS"] != nil {
            return Array(Swift.stride(from: 0, to: Swift.max(1, samples.count), by: window))
        }
        let search = Int(Self.boundarySearch * Double(c.sampleRate))
        let frame = max(1, Int(Self.boundaryFrame * Double(c.sampleRate)))
        var starts: [Int] = [0]
        var start = 0
        while start + window < samples.count {
            // Look for the lowest-energy frame in the tail of this window.
            let from = start + window - search
            var bestAt = start + window
            var bestEnergy = Float.greatestFiniteMagnitude
            var at = from
            while at + frame <= start + window {
                var sum: Float = 0
                for i in at..<(at + frame) { sum += samples[i] * samples[i] }
                if sum < bestEnergy { bestEnergy = sum; bestAt = at + frame / 2 }
                at += frame
            }
            start = bestAt
            starts.append(start)
        }
        return starts
    }

    // MARK: - Entry point

    /// Transcribe mono 16 kHz samples, reporting progress as windows complete.
    func run(samples: [Float], progress: (Double) -> Void) throws -> (String, [Word]) {
        let c = configuration
        let frames = c.encFrames
        let stride = c.jointHidden * frames
        let starts = boundaries(samples)
        let windowCount = starts.count

        var words: [Word] = []
        var done = 0

        for start in Swift.stride(from: 0, to: windowCount, by: Self.batchWindows) {
            let group = start..<min(start + Self.batchWindows, windowCount)
            var projections = [Element](repeating: 0, count: group.count * stride)
            var valids = [Int](repeating: frames, count: group.count)

            try projections.withUnsafeMutableBufferPointer { buffer in
                for (i, w) in group.enumerated() {
                    let low = starts[w]
                    let high = Swift.min(low + c.nSamples, samples.count)
                    // ceil(samples / hop / 8): rounding this down loses the final frame.
                    valids[i] = Swift.max(1, Swift.min(
                        frames, (high - low + c.hopLength * 8 - 1) / (c.hopLength * 8)))
                    try encode(window: samples[low..<high], validFrames: valids[i],
                               into: buffer.baseAddress! + i * stride)
                    done += 1
                    progress(Double(done) / Double(windowCount * 2))
                }
            }

            var tokens = [[Int]](repeating: [], count: group.count)
            var emitFrames = [[Int]](repeating: [], count: group.count)
            try decode(projections: projections, valids: valids,
                       tokens: &tokens, frames: &emitFrames)

            for (i, w) in group.enumerated() {
                // The window's position in the file is how much audio precedes
                // it, not how many encoder frames do. Subsampling rounds up --
                // 1500 mel frames become ceil(1500/8) = 188 -- so a frame-based
                // offset runs 40 ms long per window and accumulates: 9.6 s of
                // drift across an hour of audio.
                //
                // Every word the window produced is kept, including the part
                // past the next boundary. Consecutive windows overlap, so that
                // tail is what lets the splice align them; cutting purely on
                // time duplicated any word whose two estimates straddled the
                // seam, which is where "they they walked" came from.
                let produced = timedWords(tokens: tokens[i], frames: emitFrames[i],
                                          vocabulary: assets.vocabulary,
                                          secondsPerFrame: c.secondsPerFrame,
                                          timeOffset: Double(starts[w])
                                              / Double(c.sampleRate))
                if words.isEmpty {
                    words = produced
                } else {
                    words = spliceOverlap(words, produced,
                                          boundary: Double(starts[w]) / Double(c.sampleRate),
                                          overlap: Self.boundarySearch)
                }
                done += 1
                progress(Double(done) / Double(windowCount * 2))
            }
        }
        return (words.map(\.text).joined(separator: " "), words)
    }
}
#endif
