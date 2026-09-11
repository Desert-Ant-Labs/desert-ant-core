// Frame probabilities to speech spans.
//
// A port of FireRedVAD's `vad_postprocessor.py`, stage for stage, because the
// thresholds callers tune (`Cue.Options`) only mean what the upstream defaults
// mean if the stages behind them agree. The order matters and is not obvious:
// smoothing runs before thresholding, the hysteresis state machine emits a
// decision for the frame it is leaving rather than the one it entered, and
// splitting over-long spans runs last because merging after it would undo it.

import Foundation

struct Segmenter: Sendable {
    var smoothWindowFrames: Int
    var speechThreshold: Float
    var minSpeechFrames: Int
    var maxSpeechFrames: Int
    var minSilenceFrames: Int
    var mergeSilenceFrames: Int
    var extendSpeechFrames: Int

    /// Seconds per frame. The model's hop is 10 ms.
    let frameShift: Double

    private enum State { case silence, possibleSpeech, speech, possibleSilence }

    func decisions(for probs: [Float]) -> [Int] {
        guard !probs.isEmpty else { return [] }
        var d = stateMachine(threshold(smooth(probs)))
        d = fixSmoothWindowStart(d)
        d = mergeShortSilence(d)
        d = extendSpeech(d)
        return splitLongSpeech(d, probs: probs)
    }

    /// Trailing box filter. The first `window - 1` frames use the running mean
    /// of what has been seen, so the signal is not pulled toward zero at the
    /// start; the upstream implementation does this with an explicit fix-up
    /// after a full convolution and this is the same numbers.
    private func smooth(_ probs: [Float]) -> [Float] {
        guard smoothWindowFrames > 1 else { return probs }
        var out = [Float](repeating: 0, count: probs.count)
        var sum: Float = 0
        for i in 0..<probs.count {
            sum += probs[i]
            if i >= smoothWindowFrames { sum -= probs[i - smoothWindowFrames] }
            let n = Swift.min(i + 1, smoothWindowFrames)
            out[i] = sum / Float(n)
        }
        return out
    }

    private func threshold(_ probs: [Float]) -> [Bool] {
        probs.map { $0 >= speechThreshold }
    }

    /// Hysteresis: a run must last `minSpeechFrames` to become speech and
    /// `minSilenceFrames` to end it, so a single loud frame is not a segment.
    private func stateMachine(_ isSpeech: [Bool]) -> [Int] {
        guard minSpeechFrames > 0 || minSilenceFrames > 0 else {
            return isSpeech.map { $0 ? 1 : 0 }
        }
        var out = [Int](repeating: 0, count: isSpeech.count)
        var state = State.silence
        var speechStart = -1
        var silenceStart = -1
        for (t, speech) in isSpeech.enumerated() {
            switch state {
            case .silence:
                if speech { state = .possibleSpeech; speechStart = t }
            case .possibleSpeech:
                if speech {
                    if t - speechStart >= minSpeechFrames {
                        state = .speech
                        // Backfill the run that earned the promotion.
                        for i in speechStart..<t { out[i] = 1 }
                    }
                } else {
                    state = .silence
                    speechStart = -1
                }
            case .speech:
                if !speech { state = .possibleSilence; silenceStart = t }
            case .possibleSilence:
                if !speech {
                    if t - silenceStart >= minSilenceFrames {
                        state = .silence
                        speechStart = -1
                    }
                } else {
                    state = .speech
                    silenceStart = -1
                }
            }
            // A frame inside a pause short enough to be tolerated still counts
            // as speech, which is what `.possibleSilence` is for.
            out[t] = (state == .speech || state == .possibleSilence) ? 1 : 0
        }
        return out
    }

    /// The trailing smoother delays every onset by up to a window, so each
    /// rising edge is walked back that far.
    private func fixSmoothWindowStart(_ d: [Int]) -> [Int] {
        var out = d
        for t in 1..<max(1, d.count) where d[t - 1] == 0 && d[t] == 1 {
            for i in Swift.max(0, t - smoothWindowFrames)..<t { out[i] = 1 }
        }
        return out
    }

    private func mergeShortSilence(_ d: [Int]) -> [Int] {
        guard mergeSilenceFrames > 0, d.count > 1 else { return d }
        var out = d
        var silenceStart: Int? = nil
        for t in 1..<d.count {
            if d[t - 1] == 1, d[t] == 0, silenceStart == nil {
                silenceStart = t
            } else if d[t - 1] == 0, d[t] == 1, let s = silenceStart {
                if t - s < mergeSilenceFrames { for i in s..<t { out[i] = 1 } }
                silenceStart = nil
            }
        }
        return out
    }

    private func extendSpeech(_ d: [Int]) -> [Int] {
        guard extendSpeechFrames > 0 else { return d }
        var out = d
        for (t, v) in d.enumerated() where v == 1 {
            let lo = Swift.max(0, t - extendSpeechFrames)
            let hi = Swift.min(d.count, t + extendSpeechFrames + 1)
            for i in lo..<hi { out[i] = 1 }
        }
        return out
    }

    /// Break a span longer than `maxSpeechFrames` at its quietest frame, so a
    /// caller slicing audio never gets an unbounded chunk.
    private func splitLongSpeech(_ d: [Int], probs: [Float]) -> [Int] {
        guard maxSpeechFrames > 0 else { return d }
        var out = d
        for (startFrame, endFrame) in runs(d) where endFrame - startFrame > maxSpeechFrames {
            var start = 0
            let length = endFrame - startFrame
            while start < length {
                if length - start <= maxSpeechFrames { break }
                let lo = start + maxSpeechFrames / 2
                let hi = Swift.min(start + maxSpeechFrames, length)
                guard lo < hi else { break }
                var argmin = lo
                for i in lo..<hi where probs[startFrame + i] < probs[startFrame + argmin] {
                    argmin = i
                }
                out[startFrame + argmin] = 0
                start = argmin + 1
            }
        }
        return out
    }

    /// Half-open frame ranges of consecutive 1s.
    private func runs(_ d: [Int]) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var start: Int? = nil
        for (t, v) in d.enumerated() {
            if v == 1, start == nil { start = t }
            if v == 0, let s = start { out.append((s, t)); start = nil }
        }
        if let s = start { out.append((s, d.count)) }
        return out
    }

    /// Frame decisions to time spans, clamped to `duration`.
    func spans(_ d: [Int], duration: Double) -> [(start: Double, end: Double)] {
        runs(d).map { s, e in
            // A span that runs to the last frame extends by one window rather
            // than one hop, because that frame covers audio past its own start.
            let end = e == d.count
                ? Swift.min(Double(d.count) * frameShift + 0.025, duration)
                : Double(e) * frameShift
            return (Double(s) * frameShift, end)
        }
    }
}
