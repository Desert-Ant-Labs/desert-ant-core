import Foundation

enum Resampler {
    /// Linear resample mono float samples. Adequate for a log-mel frontend; for best fidelity
    /// feed 16 kHz audio directly (SpeechAnalyzer's best format is usually already suitable).
    static func toRate(_ x: [Float], from src: Double, to dst: Double) -> [Float] {
        if src == dst || x.isEmpty { return x }
        let ratio = src / dst
        let n = Int((Double(x.count) / ratio).rounded(.down))
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let pos = Double(i) * ratio
            let i0 = Int(pos), frac = Float(pos - Double(Int(pos)))
            let a = x[min(i0, x.count - 1)], b = x[min(i0 + 1, x.count - 1)]
            out[i] = a + (b - a) * frac
        }
        return out
    }
}
