import Foundation
import RealModule

/// The decision rule the model was validated with: a query is a speaker when
/// its presence is above a threshold, and talks where presence times mask (the
/// `product` rule) or the mask alone is above a second threshold, decided per
/// frame or per group of `pool` frames. The thresholds come from the sidecar.
struct Decision: Sendable, Equatable {
    enum Rule: String, Sendable, Decodable { case product, mask }

    let presenceThreshold: Float
    let maskThreshold: Float
    let rule: Rule
    let pool: Int

    /// A stretch of one query's speech, in frames.
    struct Stretch: Equatable {
        let query: Int
        /// Frame indices, the end exclusive.
        let first: Int
        let end: Int
    }

    /// Stretches of speech from `presence` `[queries]` and `masks` `[queries * frames]`, as probabilities.
    func stretches(presence: [Float], masks: [Float], frames: Int) -> [Stretch] {
        var out: [Stretch] = []
        for m in presence.indices where presence[m] > presenceThreshold {
            let row = masks[(m * frames)..<((m + 1) * frames)]
            var activity = rule == .product ? row.map { $0 * presence[m] } : Array(row)
            if pool > 1 {
                // The mean of each group of `pool` frames stands for every frame in it.
                var grouped = activity
                var start = 0
                while start < frames {
                    let end = min(start + pool, frames)
                    let mean = activity[start..<end].reduce(0, +) / Float(end - start)
                    for f in start..<end { grouped[f] = mean }
                    start = end
                }
                activity = grouped
            }
            var first: Int? = nil
            for f in 0..<frames {
                let on = activity[f] > maskThreshold
                if on, first == nil { first = f }
                if !on, let a = first {
                    out.append(Stretch(query: m, first: a, end: f))
                    first = nil
                }
            }
            if let a = first { out.append(Stretch(query: m, first: a, end: frames)) }
        }
        return out
    }

    static func sigmoid(_ z: [Float]) -> [Float] { z.map { 1 / (1 + Float.exp(-$0)) } }
}

/// Frame `f`'s centre in seconds: the first frame is centred `firstCentre` in, then every `step`.
struct FrameClock: Sendable {
    let step: Double
    let firstCentre: Double

    func centre(_ frame: Int) -> Double { firstCentre + step * Double(frame) }

    /// A stretch's bounds: half a frame either side of its first and last centres, never before zero.
    func bounds(_ stretch: Decision.Stretch) -> (start: Double, end: Double) {
        (max(centre(stretch.first) - step / 2, 0), centre(stretch.end - 1) + step / 2)
    }
}
