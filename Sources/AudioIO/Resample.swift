// Channel mixdown and sample-rate conversion for the portable decode path (and
// any host decoder that returns native rate / multichannel). Linear
// interpolation: cheap, good enough for the 16 kHz mono model front-ends these
// SDKs feed. Apple's AVAudioConverter does its own higher-quality conversion on
// that path; this keeps Linux/host output equivalent for model input.

public enum Resample {
    /// Mix interleaved `channels`-channel `interleaved` down to mono by
    /// averaging channels.
    public static func mixdownMono(_ interleaved: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return interleaved }
        let frames = interleaved.count / channels
        var out = [Float](repeating: 0, count: frames)
        let inv = 1 / Float(channels)
        for f in 0..<frames {
            var acc: Float = 0
            let base = f * channels
            for c in 0..<channels { acc += interleaved[base + c] }
            out[f] = acc * inv
        }
        return out
    }

    /// Linearly resample mono `x` from `from` Hz to `to` Hz.
    public static func linear(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard from > 0, to > 0, from != to, x.count > 1 else { return x }
        let ratio = to / from
        let outCount = Int((Double(x.count) * ratio).rounded())
        guard outCount > 0 else { return [] }
        var out = [Float](repeating: 0, count: outCount)
        let step = from / to
        for i in 0..<outCount {
            let src = Double(i) * step
            let i0 = Int(src)
            if i0 >= x.count - 1 { out[i] = x[x.count - 1]; continue }
            let frac = Float(src - Double(i0))
            out[i] = x[i0] * (1 - frac) + x[i0 + 1] * frac
        }
        return out
    }

    /// Mix down to mono and resample to `sampleRate` in one step.
    public static func toMono(_ pcm: PCM, sampleRate: Double) -> [Float] {
        let mono = mixdownMono(pcm.samples, channels: pcm.channels)
        return linear(mono, from: pcm.sampleRate, to: sampleRate)
    }
}
