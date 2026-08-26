#if canImport(CoreML)
import CoreML
import Foundation

/// The recognition pipeline: mel, encoder, and a lane-batched transducer decode.
///
/// Not `Sendable` and not reentrant: it owns preallocated buffers that every
/// call mutates. `Voz` serialises access through an actor.
final class Pipeline {
    private let assets: Assets
    private var configuration: Configuration { assets.configuration }

    // Aligning boundaries to silence costs about 13% of throughput - 292 to 255
    // RTFx on ten minutes of speech, 239 to 208 over half an hour - which is
    // the 1.12x extra windows it creates and nothing else. The scan itself does
    // not show up. Measured back to back in one binary via VOZ_FIXED_WINDOWS.

    /// Windows end at the quietest point in this much audio before the nominal
    /// boundary, so a window rarely stops in the middle of a word.
    /// Swept on half an hour of narration: 1 s puts boundaries inside speech and
    /// costs 405 deletions, 3 s costs 34, and going wider buys little for the
    /// windows it adds. Overridable so the sweep can be repeated.
    private static let boundarySearch =
        Double(ProcessInfo.processInfo.environment["VOZ_SEARCH"] ?? "") ?? 3.0
    /// Energy is measured over frames this long when looking for that point.
    private static let boundaryFrame = 0.02
    /// A frame this far below the passage's median energy is a real pause.
    private static let silenceFactor: Float = 0.05
    /// Failing that, the best dip between words.
    private static let valleyFactor: Float = 0.35
    /// How much louder than the quietest candidate a boundary may still be.
    private static let nearFloor: Float = 2.0
    /// How much of a refused window to keep when giving it a second length.
    /// Shortening by a second recovered every refused window that was tested.
    private static let retryFraction = 0.93
    /// How many retries may recover nothing before retrying is abandoned.
    private static let futileRetryLimit = 8
    /// Audio a window may leave after its last word before it counts as having
    /// stopped early. Healthy windows finish within a frame or two of their end;
    /// the ones worth rerunning leave seconds.
    /// Swept: 2.5 s beats 4 s and 6 s, which lose the Czech and Dutch gains
    /// without recovering anything in exchange.
    private static let truncationTail = 2.5
    /// A window this quiet relative to full scale is silence, and a recogniser
    /// returning nothing for it is correct rather than refusing.
    private static let speechFloor: Float = 1e-5
    /// How loud a silent stretch must be, against the window holding it, to be
    /// speech the recogniser skipped rather than a pause it was right about.
    private static let gapFloor: Float = 0.25

    /// How many windows are encoded before their decode runs. Bounds peak memory
    /// (each window's encoder output is ~240 KB) and gives progress somewhere to
    /// be reported from, while staying long enough that the decoder's lanes stay
    /// full for all but the last group.
    private static let batchWindows =
        Int(ProcessInfo.processInfo.environment["VOZ_BATCH_WINDOWS"] ?? "") ?? 64

    private let rows: Buffer
    private let melOut: Buffer
    private let keyBias: Buffer
    private let padMask: Buffer
    private let melMask: Buffer
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
        melMask = try Buffer([1, 1, 1, c.validFrames])
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
            "audio_rows": MLFeatureValue(multiArray: rows.array),
            "mel_mask": MLFeatureValue(multiArray: melMask.array)])
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
        // Normalization statistics must be taken over the frames that actually
        // hold audio. A window is a fixed 15 s, so a five-second clip is two
        // thirds padding, and including it drags the mean down and squashes the
        // speech: the frontend then agrees with the reference implementation to
        // 2.7 dB rather than 140 dB, and short clips lose accuracy badly.
        let melFrames = configuration.validFrames
        let melValid = max(1, min(melFrames, window.count / configuration.hopLength + 1))
        melMask.ptr.update(repeating: 1, count: melValid)
        for i in melValid..<melFrames { melMask.ptr[i] = 0 }
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
    private func decode(projections: [Element], valids: [Int], ends: inout [[Int]],
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
                        // How many frames the recogniser says this token spans.
                        // It predicts one per token and the decode loop uses it
                        // to advance; kept here because it is also the only
                        // acoustic evidence available for where a word ends.
                        ends[window].append(position[lane] + offset + duration)
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

    /// The longest stretch of a window that produced no words, as frames.
    ///
    /// Counts the run before the first word and the run after the last as well
    /// as the runs between, so a window that starts late, stops early, or falls
    /// silent in the middle are all the same question.
    private func widestSilence(_ frames: [Int], upTo valid: Int) -> (Int, Int) {
        var best = (0, 0)
        var previous = 0
        for frame in frames {
            if frame - previous > best.1 - best.0 { best = (previous, frame) }
            previous = Swift.max(previous, frame)
        }
        if valid - previous > best.1 - best.0 { best = (previous, valid) }
        return best
    }

    /// The quietest 20 ms in the second before `at` and the half second after.
    ///
    /// Used to place a recovery window, so that it begins between words like
    /// every other window rather than wherever the previous one happened to
    /// stop.
    private func quietestPoint(near at: Int, from lowest: Int, limit: Int,
                               audio: (Int) -> Float) -> Int {
        let c = configuration
        let frame = Swift.max(1, Int(Self.boundaryFrame * Double(c.sampleRate)))
        let first = Swift.max(lowest, at - c.sampleRate)
        let last = Swift.min(limit - frame, at + c.sampleRate / 2)
        guard last > first else { return Swift.max(lowest, Swift.min(at, limit - 1)) }
        var bestAt = at
        var best = Float.greatestFiniteMagnitude
        var index = first
        while index + frame <= last {
            var sum: Float = 0
            for i in index..<(index + frame) {
                let value = audio(i)
                sum += value * value
            }
            if sum < best { best = sum; bestAt = index + frame / 2 }
            index += frame
        }
        return bestAt
    }

    /// Mean square level of a span, for comparing one stretch against another.
    private func loudness(_ window: ArraySlice<Float>) -> Float {
        var sum: Float = 0
        var count = 0
        var i = window.startIndex
        while i < window.endIndex {
            sum += window[i] * window[i]
            count += 1
            i += 16
        }
        return count > 0 ? sum / Float(count) : 0
    }

    /// Does this window hold anything worth transcribing?
    ///
    /// Only used to tell a window the recogniser refused from one that is
    /// genuinely silent, so that silence is not re-run pointlessly.
    private func holdsSpeech(_ window: ArraySlice<Float>) -> Bool {
        var sum: Float = 0
        var count = 0
        var i = window.startIndex
        while i < window.endIndex {
            sum += window[i] * window[i]
            count += 1
            i += 16   // every sixteenth sample is plenty for a level check
        }
        return count > 0 && sum / Float(count) > Self.speechFloor
    }

    /// Where each window should start, in samples.
    ///
    /// A fixed 15 s grid cuts wherever it lands, and the model is measurably
    /// sensitive to that: a crop beginning mid-word can decode to nothing at all
    /// or stop emitting well before its end, while the same audio at any other
    /// offset transcribes normally. That is the model's behaviour and not this
    /// export's - float32 PyTorch reproduces it, and the encoder matches NeMo's
    /// reference to 116 dB - so the fix is to stop handing it crops it handles
    /// badly rather than to check its output afterwards.
    ///
    /// The model was trained on utterances, which begin and end in silence, so
    /// each boundary is placed at the quietest point in the last few seconds of
    /// the window. Windows are therefore up to `nSamples` long and usually a
    /// little shorter, and each one starts where the speaker paused.
    /// Where the window after `start` should begin, given a way to read audio.
    ///
    /// Only ever looks inside `[start, start + nSamples]`, which is what lets a
    /// long file be walked with a sliding buffer instead of being held whole.
    private func nextBoundary(after start: Int, audio: (Int) -> Float) -> Int {
        let c = configuration
        let window = c.nSamples
        let search = Int(Self.boundarySearch * Double(c.sampleRate))
        let frame = max(1, Int(Self.boundaryFrame * Double(c.sampleRate)))
        let from = start + window - search
        var scores: [(at: Int, energy: Float)] = []
        var at = from
        while at + frame <= start + window {
            var sum: Float = 0
            for i in at..<(at + frame) { sum += audio(i) * audio(i) }
            scores.append((at + frame / 2, sum / Float(frame)))
            at += frame
        }
        guard !scores.isEmpty else { return start + window }
        var bestAt = start + window
        let floorEnergy = Swift.max(scores.map(\.energy).min() ?? 0, 1e-9)
        let admissible = scores.filter { $0.energy <= Self.nearFloor * floorEnergy }
        let pool = admissible.isEmpty ? scores : admissible
        var bestScore = Float.greatestFiniteMagnitude
        for candidate in pool {
            let earliness = Float(start + window - candidate.at) / Float(search)
            let score = candidate.energy * (1 + earliness)
            if score <= bestScore { bestScore = score; bestAt = candidate.at }
        }
        return bestAt
    }


    // MARK: - Entry point

    /// Transcribe a stream of mono 16 kHz samples.
    ///
    /// The audio is walked with a sliding buffer rather than held whole. Only
    /// the batch being worked on has to be resident, so peak memory is set by
    /// the batch size and not by the length of the recording: an hour of audio
    /// is 230 MB of `Float`, and a video editor has a timeline and its own
    /// buffers to fit alongside it.
    func run(stream: inout some AudioStream, progress: (Double) -> Void) throws -> (String, [Word]) {
        let c = configuration
        let frames = c.encFrames
        let stride = c.jointHidden * frames
        let window = c.nSamples

        var buffer: [Float] = []
        var origin = 0                    // absolute index of buffer[0]
        var exhausted = false
        var available: Int { origin + buffer.count }

        /// Read until the buffer covers up to `absolute`, or the source ends.
        func ensure(through absolute: Int) throws {
            while !exhausted && available < absolute {
                let wanted = Swift.max(absolute - available, c.sampleRate * 4)
                if try stream.read(wanted, into: &buffer) == 0 { exhausted = true }
            }
        }
        /// Release audio behind `absolute`; it is never looked at again.
        ///
        /// Rebuilt rather than trimmed in place: `removeFirst` keeps the array's
        /// capacity, so the storage would stay as large as the largest span ever
        /// held and none of this would give memory back.
        func release(before absolute: Int) {
            let drop = Swift.min(Swift.max(absolute - origin, 0), buffer.count)
            guard drop > 0 else { return }
            buffer = Array(buffer[drop...])
            origin += drop
        }
        func slice(_ low: Int, _ high: Int) -> ArraySlice<Float> {
            buffer[(low - origin)..<(high - origin)]
        }
        let total = stream.totalSamples
        // Progress is how much audio has been read and encoded, which advances
        // in order through the file. Reporting from the splice pass as well sent
        // it back to the start of the batch each time, since the two passes walk
        // the same windows.
        func reported(_ at: Int) -> Double {
            guard let total, total > 0 else { return 0 }
            return Swift.min(1, Double(at + window) / Double(total))
        }

        var words: [Word] = []
        var futileRetries = 0
        var starts: [Int] = [0]
        var processed = 0

        while true {
            // Extend the boundary list to fill a batch, reading only as far as
            // each decision needs. This has to happen before the loop decides
            // it is finished: checking `processed < starts.count` first stops
            // after a single batch, which silently truncated any file longer
            // than one, and left the transcript reading perfectly well.
            while starts.count - processed < Self.batchWindows {
                let last = starts[starts.count - 1]
                try ensure(through: last + window + 1)
                guard available > last + window else { break }
                starts.append(nextBoundary(after: last) { buffer[$0 - origin] })
            }
            guard processed < starts.count else { break }
            let group = processed..<Swift.min(processed + Self.batchWindows, starts.count)
            // Everything before this batch is finished with. Releasing here
            // rather than after the batch matters: at that point the boundary
            // list has already been extended to exactly the batch that was just
            // processed, so the release never fired and the buffer grew with the
            // file - 5.8 MB for every minute of audio.
            release(before: starts[group.lowerBound])
            try ensure(through: starts[group.upperBound - 1] + window)
            var projections = [Element](repeating: 0, count: group.count * stride)
            var valids = [Int](repeating: frames, count: group.count)

            try projections.withUnsafeMutableBufferPointer { buffer in
                for (i, w) in group.enumerated() {
                    let low = starts[w]
                    let high = Swift.min(low + c.nSamples, available)
                    // ceil(samples / hop / 8): rounding this down loses the final frame.
                    valids[i] = Swift.max(1, Swift.min(
                        frames, (high - low + c.hopLength * 8 - 1) / (c.hopLength * 8)))
                    try encode(window: slice(low, high), validFrames: valids[i],
                               into: buffer.baseAddress! + i * stride)
                    progress(reported(low))
                }
            }

            var tokens = [[Int]](repeating: [], count: group.count)
            var emitFrames = [[Int]](repeating: [], count: group.count)
            var emitEnds = [[Int]](repeating: [], count: group.count)
            var extra = [Int: ([Int], [Int], [Int], Int)]()
            try decode(projections: projections, valids: valids, ends: &emitEnds,
                       tokens: &tokens, frames: &emitFrames)

            // Some windows come back empty even though they are full of speech.
            // This is the recogniser's own behaviour and not this runtime's: the
            // reference implementation refuses exactly the same crops, and on
            // one ten-minute file about a quarter of all fifteen-second crops at
            // half-second spacing produce nothing at all. It is not the audio
            // level, and it is not where the crop starts relative to a word; the
            // same seconds transcribe normally at a different crop length, and
            // the boundary between working and refusing moves with the content.
            //
            // Nothing in the boundary search can steer around that, so a refused
            // window is given the one thing that reliably changes the outcome: a
            // different length. Every refused window tested recovered when its
            // audio was shortened, and this costs a second pass only over the
            // windows that produced nothing, which is normally none of them.
            // Audio that is not speech at all - music, room tone, a held
            // note - legitimately produces nothing from every window, and
            // retrying all of them doubles the work to learn that. So a run of
            // retries that recovers nothing switches retrying off, and any
            // recovery switches it back on: the cost is bounded on material
            // that has nothing to say, without giving up on a file that is
            // quiet for a while and then starts talking.
            // A window can fail in two ways, and they look different. It can
            // produce nothing at all, or it can produce a plausible transcript
            // and stop partway through - one French window emitted 37% of its
            // audio and read perfectly, so nothing downstream could tell. Both
            // are the same behaviour and both are fixed by the same thing,
            // running the window at a different length: that one goes from 37%
            // to 99% at fourteen seconds instead of fifteen.
            //
            // A window counts as having stopped early by how much audio it left
            // after its last word, and only if that audio holds speech, so one
            // whose tail is genuinely silent is left alone.
            let refused = futileRetries >= Self.futileRetryLimit ? [] :
                group.enumerated().filter { i, w in
                    let low = starts[w]
                    let high = Swift.min(low + c.nSamples, available)
                    if tokens[i].isEmpty { return holdsSpeech(slice(low, high)) }
                    // The hole is not always at the end. A Czech window reached
                    // its final frame and still emitted a third of the words its
                    // neighbours did, because it said nothing at all across ten
                    // seconds in the middle. Looking only at what follows the
                    // last word misses that entirely, so this takes the largest
                    // silence between consecutive words, wherever it falls.
                    let (from, to) = widestSilence(emitFrames[i], upTo: valids[i])
                    guard Double(to - from) * c.secondsPerFrame > Self.truncationTail
                    else { return false }
                    let a = Swift.min(high, low + Int(Double(from) * c.secondsPerFrame
                        * Double(c.sampleRate)))
                    let b = Swift.min(high, low + Int(Double(to) * c.secondsPerFrame
                        * Double(c.sampleRate)))
                    // Judged against this window's own loudness rather than an
                    // absolute floor: a pause with room tone in it clears a
                    // fixed threshold, and rerunning genuine pauses costs more
                    // than it recovers.
                    return a < b && loudness(slice(a, b)) > Self.gapFloor * loudness(slice(low, high))
                }
            if !refused.isEmpty {
                // Retried together rather than one at a time, for the same
                // reason the first pass batches: a decode call costs about the
                // same whatever it carries. Run singly, a file of pure
                // non-speech - where every window legitimately produces
                // nothing and every one is retried - ran at a third of its
                // usual speed instead of half.
                var retryProjections = [Element](repeating: 0, count: refused.count * stride)
                var retryValids = [Int](repeating: frames, count: refused.count)
                var retryStarts = [Int](repeating: 0, count: refused.count)
                try retryProjections.withUnsafeMutableBufferPointer { out in
                    for (slot, entry) in refused.enumerated() {
                        let windowStart = starts[entry.element]
                        // Where to run the window again. A window that produced
                        // nothing gets the same audio at a different length,
                        // which is the only thing that reliably changes the
                        // outcome. A window that stopped early gets something
                        // better than luck: the audio it missed, as a window of
                        // its own, starting a second before it gave up so the
                        // splice has an overlap to align on. Rerunning a
                        // truncated window at a different length is a coin flip
                        // - it rescued one of French's three worst and left the
                        // other two exactly where they were - because the model
                        // is sensitive to the crop in a way that does not
                        // reward guessing.
                        let stopped = widestSilence(emitFrames[entry.offset],
                                                    upTo: valids[entry.offset]).0
                        // Start the recovery window at the quietest point near
                        // where the last one gave up, rather than exactly there.
                        // Every other window start is chosen this way for the
                        // same reason: the recogniser is sensitive to where a
                        // crop begins, so handing it an arbitrary one wastes the
                        // rerun.
                        let gaveUp = windowStart
                            + Int(Double(stopped) * c.secondsPerFrame * Double(c.sampleRate))
                        let low = tokens[entry.offset].isEmpty ? windowStart
                            // `buffer` is the audio, not `out`: this searches the
                            // waveform for a quiet point. The two were briefly the
                            // same name, and this read went into the projections
                            // with sample indices, which is unmapped memory a few
                            // megabytes in.
                            : quietestPoint(near: gaveUp, from: windowStart,
                                            limit: available, audio: { buffer[$0 - origin] })
                        let high = Swift.min(low + c.nSamples, available)
                        let shortened = tokens[entry.offset].isEmpty
                            ? low + Int(Self.retryFraction * Double(high - low)) : high
                        retryStarts[slot] = low
                        retryValids[slot] = Swift.max(1, Swift.min(
                            frames, (shortened - low + c.hopLength * 8 - 1) / (c.hopLength * 8)))
                        try encode(window: slice(low, shortened),
                                   validFrames: retryValids[slot],
                                   into: out.baseAddress! + slot * stride)
                    }
                }
                var retryTokens = [[Int]](repeating: [], count: refused.count)
                var retryFrames = [[Int]](repeating: [], count: refused.count)
                var retryEnds = [[Int]](repeating: [], count: refused.count)
                try decode(projections: retryProjections, valids: retryValids,
                           ends: &retryEnds,
                           tokens: &retryTokens, frames: &retryFrames)
                for (slot, entry) in refused.enumerated() {
                    if tokens[entry.offset].isEmpty {
                        // Nothing to keep, so the rerun simply replaces it.
                        tokens[entry.offset] = retryTokens[slot]
                        emitFrames[entry.offset] = retryFrames[slot]
                        emitEnds[entry.offset] = retryEnds[slot]
                    } else {
                        // The window said something before it stopped, and that
                        // part is good. The rerun covers what came after it, on
                        // its own timeline, and is spliced in behind it.
                        extra[entry.offset] = (retryTokens[slot], retryFrames[slot],
                                               retryEnds[slot], retryStarts[slot])
                    }
                    let recovered = !retryTokens[slot].isEmpty
                        && Double(retryValids[slot] - (retryFrames[slot].last ?? 0))
                            * c.secondsPerFrame <= Self.truncationTail
                    if recovered { futileRetries = 0 } else { futileRetries += 1 }
                }
            }

            for (i, w) in group.enumerated() {
                // The window's position in the file is how much audio precedes
                // it, not how many encoder frames do. Subsampling rounds up --
                // 1500 mel frames become ceil(1500/8) = 188 - so a frame-based
                // offset runs 40 ms long per window and accumulates: 9.6 s of
                // drift across an hour of audio.
                //
                // Every word the window produced is kept, including the part
                // past the next boundary. Consecutive windows overlap, so that
                // tail is what lets the splice align them; cutting purely on
                // time duplicated any word whose two estimates straddled the
                // seam, which is where "they they walked" came from.
                let low = starts[w]
                let high = Swift.min(low + c.nSamples, available)
                let produced = refineEnds(
                    timedWords(tokens: tokens[i], frames: emitFrames[i],
                               ends: emitEnds[i],
                               vocabulary: assets.vocabulary,
                               secondsPerFrame: c.secondsPerFrame,
                               timeOffset: Double(low) / Double(c.sampleRate)),
                    samples: slice(low, high),
                    windowStart: Double(low) / Double(c.sampleRate),
                    sampleRate: Double(c.sampleRate))
                func join(_ produced: [Word], at sample: Int) {
                    if words.isEmpty {
                        words = produced
                    } else {
                        words = spliceOverlap(words, produced,
                                              boundary: Double(sample) / Double(c.sampleRate),
                                              overlap: Self.boundarySearch)
                    }
                }
                join(produced, at: starts[w])
                if let (t, f, e, at) = extra[i] {
                    join(refineEnds(timedWords(tokens: t, frames: f, ends: e,
                                               vocabulary: assets.vocabulary,
                                               secondsPerFrame: c.secondsPerFrame,
                                               timeOffset: Double(at) / Double(c.sampleRate)),
                                    samples: slice(at, Swift.min(at + c.nSamples, available)),
                                    windowStart: Double(at) / Double(c.sampleRate),
                                    sampleRate: Double(c.sampleRate)),
                         at: at)
                }
            }
            processed = group.upperBound
        }
        words = clampMonotonic(words)
        return (words.map(\.text).joined(separator: " "), words)
    }
}
#endif
