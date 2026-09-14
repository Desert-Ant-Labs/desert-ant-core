#if canImport(CoreML)
import CoreML
import Foundation

/// The streaming recognition pipeline: one chunk in, whatever words it finished.
///
/// Not `Sendable` and not reentrant; it owns preallocated buffers that every
/// call mutates, and ``LiveTranscriber`` serialises access to it.
///
/// Shaped by one measurement. The streaming encoder runs 4 frames through 24
/// conformer layers against 300+ MB of weights, an arithmetic intensity around
/// 2.6 FLOP/byte where the M1's ridge point is ~141, so it is bandwidth-bound by
/// a factor of fifty and its cost does not depend on the chunk length: measured
/// 31.16 / 30.94 / 30.84 / 31.71 ms for chunks of 1 / 2 / 8 / 16 frames, which
/// is 16x the arithmetic for 1.8% more time. Chunk size is therefore a pure
/// latency dial, and everything below is arranged so nothing else gets in the
/// way of it.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, *)
final class LivePipeline {
    private let assets: LiveAssets
    private var c: Configuration { assets.configuration }
    private var live: LiveConfiguration { assets.live }

    // Encoder I/O. The three caches are the whole of the stream's memory.
    private let rows: Buffer
    private let normMean: Buffer
    private let normVar: Buffer
    private let alpha: Buffer
    private let kCache: Buffer
    private let vCache: Buffer
    private let convCache: Buffer
    private let cacheMask: Buffer
    private let encOut: Buffer
    private let normMeanOut: Buffer
    private let normVarOut: Buffer
    private let kNew: Buffer
    private let vNew: Buffer
    private let convNew: Buffer

    // Decode I/O, one lane.
    private let embed: Buffer
    private let hIn: Buffer
    private let cIn: Buffer
    private let encStep: Buffer
    private let logitsOut: Buffer
    private let hOut: Buffer
    private let cOut: Buffer

    private let encoderProvider: MLDictionaryFeatureProvider
    private let stepProvider: MLDictionaryFeatureProvider
    private let encoderOptions = MLPredictionOptions()
    private let stepOptions = MLPredictionOptions()

    // Stream state.
    private var chunkIndex = 0
    private var validCache = 0
    private var melSeen = 0
    private var label: Int
    private var emitted = 0

    init(assets: LiveAssets) throws {
        self.assets = assets
        let c = assets.configuration
        let l = assets.live
        let hidden = c.predLayers * c.predHidden
        label = c.blankIdx

        rows = try Buffer([1, c.hopLength, 1, l.nRows])
        normMean = try Buffer([1, c.nMels, 1, 1])
        normVar = try Buffer([1, c.nMels, 1, 1])
        alpha = try Buffer([1, 1, 1, 1])
        kCache = try Buffer([1, l.cacheChannels, 1, l.leftContext])
        vCache = try Buffer([1, l.cacheChannels, 1, l.leftContext])
        convCache = try Buffer([1, l.cacheChannels, 1, l.convKernel - 1])
        cacheMask = try Buffer([1, l.leftContext + l.chunkFrames, 1, 1])
        encOut = try Buffer([1, c.jointHidden, 1, l.chunkFrames])
        normMeanOut = try Buffer([1, c.nMels, 1, 1])
        normVarOut = try Buffer([1, c.nMels, 1, 1])
        kNew = try Buffer([1, l.cacheChannels, 1, l.chunkFrames])
        vNew = try Buffer([1, l.cacheChannels, 1, l.chunkFrames])
        convNew = try Buffer([1, l.cacheChannels, 1, l.convKernel - 1])

        embed = try Buffer([1, c.predHidden, 1, 1])
        hIn = try Buffer([1, hidden, 1, 1])
        cIn = try Buffer([1, hidden, 1, 1])
        encStep = try Buffer([1, c.jointHidden, 1, l.decodeWidth])
        logitsOut = try Buffer([1, c.vocabSize + 1 + c.durations.count, 1, l.decodeWidth])
        hOut = try Buffer([1, hidden, 1, 1])
        cOut = try Buffer([1, hidden, 1, 1])

        encoderProvider = try MLDictionaryFeatureProvider(dictionary: [
            "rows": MLFeatureValue(multiArray: rows.array),
            "norm_mean": MLFeatureValue(multiArray: normMean.array),
            "norm_var": MLFeatureValue(multiArray: normVar.array),
            "alpha": MLFeatureValue(multiArray: alpha.array),
            "k_cache": MLFeatureValue(multiArray: kCache.array),
            "v_cache": MLFeatureValue(multiArray: vCache.array),
            "conv_cache": MLFeatureValue(multiArray: convCache.array),
            "cache_mask": MLFeatureValue(multiArray: cacheMask.array)])
        stepProvider = try MLDictionaryFeatureProvider(dictionary: [
            "embed": MLFeatureValue(multiArray: embed.array),
            "h_in": MLFeatureValue(multiArray: hIn.array),
            "c_in": MLFeatureValue(multiArray: cIn.array),
            "enc_step": MLFeatureValue(multiArray: encStep.array)])
        encoderOptions.outputBackings = [
            "enc_proj": encOut.array,
            "norm_mean_out": normMeanOut.array, "norm_var_out": normVarOut.array,
            "k_new": kNew.array, "v_new": vNew.array, "conv_new": convNew.array]
        stepOptions.outputBackings = [
            "logits": logitsOut.array, "h_out": hOut.array, "c_out": cOut.array]

        reset()
    }

    /// Advance the chunk clock without running the graph.
    ///
    /// Used when the bundle's streaming weights are untrained: the geometry
    /// still has to march forward, because it paces the second pass and defines
    /// which audio the ring may release.
    func skip() { chunkIndex += 1 }

    /// Begin a new utterance: caches cleared, normalizer back to its prior.
    func reset() {
        chunkIndex = 0
        validCache = 0
        melSeen = 0
        label = c.blankIdx
        emitted = 0
        kCache.zero(); vCache.zero(); convCache.zero()
        hIn.zero(); cIn.zero(); embed.zero(); encStep.zero()
        normMean.zero()
        // Variance starts at one, not zero: it is divided by. A zero here makes
        // the first chunk's normalized mel enormous and the encoder saturates.
        normVar.ptr.update(repeating: 1, count: normVar.count)
    }

    var framesEmitted: Int { chunkIndex * live.chunkFrames }

    /// Samples that must have arrived before the next chunk can run.
    var samplesNeeded: Int {
        live.samplesNeeded(chunk: chunkIndex, hopLength: c.hopLength, nFFT: c.nFFT)
    }

    /// Stream index of the earliest sample the next chunk reads.
    var firstSampleNeeded: Int {
        live.firstSample(chunk: chunkIndex, hopLength: c.hopLength, nFFT: c.nFFT)
    }

    /// Samples one chunk reads, which is the window the caller must hand over.
    var windowSamples: Int { live.nRows * c.hopLength }

    // MARK: - Frontend

    /// Gather one chunk's rows out of the caller's ring.
    ///
    /// The host's entire frontend responsibility: framing, windowing, the DFT,
    /// the mel filterbank, the log and the normalization are all inside the
    /// encoder. `available` is the ring's contents and `ringOrigin` the stream
    /// index of its first sample; samples outside it read as zero, which is
    /// `center=True` padding at the start and the correct thing at the end.
    private func frame(ring: UnsafeBufferPointer<Float>, ringOrigin: Int) {
        rows.zero()
        let hop = c.hopLength
        let n = live.nRows
        let lo = firstSampleNeeded
        let low = Swift.max(lo, ringOrigin)
        let high = Swift.min(lo + n * hop, ringOrigin + ring.count)
        guard high > low else { return }
        // Row-major on the way in, channel-major on the way out: sample s of the
        // chunk lands at row s / hop, lane s % hop, and the model reads lanes as
        // channels. Writing it one sample at a time keeps the transpose here
        // rather than asking Core ML for a strided copy it would do slower.
        for s in low..<high {
            let value = ring[s - ringOrigin]
            if value == 0 { continue }
            let k = s - lo
            rows.ptr[(k % hop) * n + k / hop] = Element(value)
        }
    }

    /// Weight of the newest chunk in the running mel statistics.
    ///
    /// A running average while the stream is short and an exponential one once
    /// it is long. Both are the same update; the schedule is 1/n until 1/n falls
    /// below the EMA coefficient, so the first second of a stream normalizes
    /// against what it has actually heard rather than against a prior it has no
    /// reason to trust. The offline model normalizes over a whole 15 s window
    /// and a stream has no window, which is the difference this covers.
    private var normAlpha: Float {
        let per = Float(live.melFrames)
        let tau = Float(live.normTauSeconds * Double(c.sampleRate) / Double(c.hopLength))
        return Swift.max(per / tau, per / Swift.max(Float(melSeen) + per, per))
    }

    // MARK: - One chunk

    /// Run the encoder over one chunk and decode whatever it finished.
    ///
    /// Returns the tokens emitted, with the encoder frame each came from. The
    /// frame is exact rather than inferred: TDT states how far to advance after
    /// every emission.
    func process(ring: UnsafeBufferPointer<Float>, ringOrigin: Int,
                 tokens: inout [Int], frames: inout [Int], ends: inout [Int]) throws {
        frame(ring: ring, ringOrigin: ringOrigin)
        alpha.ptr[0] = Element(normAlpha)

        // Everything in the cache is fabricated until real frames have filled
        // it. Attention is told so rather than being left to average over 64
        // frames of zero, which is not silence: it is the mean of the layer's
        // own activation distribution, and confidently wrong.
        cacheMask.zero()
        if validCache < live.leftContext {
            for i in 0..<(live.leftContext - validCache) {
                cacheMask.ptr[i] = Element(-40000)   // float16 stand-in for -infinity
            }
        }
        _ = try assets.encoder.prediction(from: encoderProvider, options: encoderOptions)

        try decode(tokens: &tokens, frames: &frames, ends: &ends)
        commitCaches()
        chunkIndex += 1
    }

    /// Slide the caches by one chunk.
    ///
    /// A shift rather than a ring: a ring would save this copy but would
    /// scramble the position each cached key is indexed against, and that
    /// indexing is what makes a bounded cache legal. The copy is a few
    /// megabytes per chunk, which is under a percent of the bandwidth the
    /// weights already cost.
    private func commitCaches() {
        let cf = live.chunkFrames
        let l = live.leftContext
        let channels = live.cacheChannels
        for (cache, fresh) in [(kCache, kNew), (vCache, vNew)] {
            for ch in 0..<channels {
                let row = cache.ptr + ch * l
                // memmove semantics: the regions overlap.
                (row).update(from: row + cf, count: l - cf)
                (row + l - cf).update(from: fresh.ptr + ch * cf, count: cf)
            }
        }
        convCache.ptr.update(from: convNew.ptr, count: convCache.count)
        normMean.ptr.update(from: normMeanOut.ptr, count: normMean.count)
        normVar.ptr.update(from: normVarOut.ptr, count: normVar.count)
        validCache = Swift.min(l, validCache + cf)
        melSeen += live.melFrames
    }

    // MARK: - Decode

    /// Greedy TDT decode over the chunk's frames, one lane.
    ///
    /// The prediction state only changes when a token is emitted, so a chunk
    /// that is all blanks costs exactly one dispatch however many frames it
    /// holds. That is why `enc_step` is `chunkFrames` wide rather than 1, and
    /// why silence between words is nearly free.
    private func decode(tokens: inout [Int], frames: inout [Int],
                        ends: inout [Int]) throws {
        let width = live.decodeWidth
        let span = live.chunkFrames
        let joint = c.jointHidden
        let vocab = c.vocabSize
        let blank = c.blankIdx
        let hidden = c.predLayers * c.predHidden
        let base = chunkIndex * span

        var position = 0
        while position < span {
            assets.withEmbedding { table in
                embed.ptr.update(from: table.baseAddress! + label * c.predHidden,
                                 count: c.predHidden)
            }
            let take = Swift.min(width, span - position)
            for channel in 0..<joint {
                let destination = encStep.ptr + channel * width
                destination.update(from: encOut.ptr + channel * span + position, count: take)
                if take < width {
                    (destination + take).update(repeating: 0, count: width - take)
                }
            }
            _ = try assets.decodeStep.prediction(from: stepProvider, options: stepOptions)

            var offset = 0
            var didEmit = false
            while offset < take {
                // Argmax on the host, not in the graph. Folding it in saves
                // 66 KB of transfer per call and costs the model's Neural
                // Engine residency: the reduction axis limit is 2048 and the
                // vocabulary is 8193, so both argmaxes plan to CPU and drag a
                // slice with them. Measured 43/46 ops on ANE with the reduction
                // in, 42/42 with it out.
                var best = 0
                var bestValue = Float(logitsOut.ptr[offset])
                for k in 1...vocab {
                    let value = Float(logitsOut.ptr[k * width + offset])
                    if value > bestValue { bestValue = value; best = k }
                }
                var bestDuration = 0
                var bestDurationValue = Float(logitsOut.ptr[(vocab + 1) * width + offset])
                for k in 1..<c.durations.count {
                    let value = Float(logitsOut.ptr[(vocab + 1 + k) * width + offset])
                    if value > bestDurationValue {
                        bestDurationValue = value
                        bestDuration = k
                    }
                }
                let duration = c.durations[bestDuration]
                if best != blank {
                    tokens.append(best)
                    frames.append(base + position + offset)
                    ends.append(base + position + offset + duration)
                    hIn.ptr.update(from: hOut.ptr, count: hidden)
                    cIn.ptr.update(from: cOut.ptr, count: hidden)
                    label = best
                    emitted += 1
                    var step = duration
                    // TDT may predict a zero duration; force progress so the
                    // lane cannot emit forever on one frame.
                    if step == 0 && emitted >= 10 { step = 1; emitted = 0 }
                    position += offset + step
                    didEmit = true
                    break
                }
                emitted = 0
                offset += duration > 0 ? duration : 1
            }
            if !didEmit { position += Swift.max(offset, 1) }
        }
    }
}
#endif
