#if canImport(CoreML)
import CoreML
import Foundation

/// Runs the fixed-shape graph over an arbitrary number of frames.
///
/// Windows are anchored on real feature frames rather than padded into place.
/// That is not a detail: the network zero-pads in *projection* space inside each
/// FSMN layer, and the stem's biases map a zero filterbank frame to a non-zero
/// projection, so inventing feature frames at an utterance boundary produces
/// different output than the reference. Anchoring means the first window starts
/// at frame 0 and the last ends at the final frame, and the graph's own internal
/// padding reproduces the reference boundary behaviour.
struct Pipeline {
    let assets: Assets
    private let window: Int
    private let lookback: Int
    private let lookahead: Int
    private let mels: Int

    init(assets: Assets) {
        self.assets = assets
        window = assets.configuration.windowFrames
        lookback = assets.configuration.lookbackFrames
        lookahead = assets.configuration.lookaheadFrames
        mels = assets.configuration.mels
    }

    /// Which windows cover `frames`, as (offset, first output, end output).
    func windows(frames: Int) -> [(offset: Int, lo: Int, hi: Int)] {
        guard frames > 0 else { return [] }
        if frames <= window { return [(0, 0, frames)] }
        var out: [(Int, Int, Int)] = []
        var done = Swift.min(window - lookahead, frames)
        out.append((0, 0, done))
        while done < frames {
            let offset = Swift.min(done - lookback, frames - window)
            let hi = offset + window >= frames ? frames : offset + window - lookahead
            out.append((offset, done, hi))
            done = hi
        }
        return out
    }

    /// Per-frame speech probability for `features` (frame-major, frames * mels).
    ///
    /// `silenceFrame` fills the tail when a clip is shorter than one window; it
    /// is the filterbank of digital silence, so the padded region stays on the
    /// model's input manifold instead of being an impossible all-zero frame.
    func probabilities(features: [Float], frames: Int, silenceFrame: [Float],
                       progress: (Double) -> Void) throws -> [Float] {
        guard frames > 0 else { return [] }
        var out = [Float](repeating: 0, count: frames)

        let input = try MLMultiArray(shape: [1, NSNumber(value: mels), 1,
                                             NSNumber(value: window)],
                                     dataType: .float16)
        let plan = windows(frames: frames)
        for (index, w) in plan.enumerated() {
            input.withUnsafeMutableBytes { raw, strides in
                let dst = raw.bindMemory(to: Float16.self)
                // Model layout is (1, mels, 1, window): channel-major, time last.
                let melStride = strides[1]
                for t in 0..<window {
                    let source = w.offset + t
                    if source < frames {
                        let row = source * mels
                        for m in 0..<mels {
                            dst[m * melStride + t] = Float16(features[row + m])
                        }
                    } else {
                        for m in 0..<mels {
                            dst[m * melStride + t] = Float16(silenceFrame[m])
                        }
                    }
                }
            }
            let provider = try MLDictionaryFeatureProvider(
                dictionary: [assets.configuration.input: MLFeatureValue(multiArray: input)])
            let result = try assets.model.prediction(from: provider)
            guard let probs = result.featureValue(for: assets.configuration.output)?
                .multiArrayValue else {
                throw CueError.invalidModel("model produced no \(assets.configuration.output)")
            }
            probs.withUnsafeBytes { raw in
                let src = raw.bindMemory(to: Float16.self)
                for f in w.lo..<w.hi { out[f] = Float(src[f - w.offset]) }
            }
            progress(Double(index + 1) / Double(plan.count))
        }
        return out
    }
}
#endif
