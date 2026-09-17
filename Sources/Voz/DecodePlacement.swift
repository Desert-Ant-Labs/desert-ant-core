#if canImport(CoreML)
import CoreML
import Inference
import Foundation

/// Which processor the decode step runs on, decided by measuring this machine.
///
/// The decode is 281 dispatches of a sixteen-lane joint over ten minutes of
/// speech, each too small to fill anything, so it is priced by what a dispatch
/// costs rather than by arithmetic - and that price inverts between chips. The
/// stage alone, ms per dispatch:
///
///                   engine    CPU
///   iPhone 16 Pro     1.76    5.32
///   M1                2.26    4.16
///   M5                1.36    1.97
///   M3 Ultra          4.33    0.95
///
/// An A18 dispatches this faster than an M3 Ultra does, and an Ultra's CPU runs
/// it four times faster than its own engine. Two Macs of the same family want
/// opposite answers, so "desktop" is not a category and any table here is a
/// statement about the machines someone owned when they wrote it.
///
/// Core ML's own estimate does not rescue it. `MLComputePlan` costs this stage
/// per machine without running it, and ranks the engine cheaper on all three
/// Macs - correct on an M1 and an M5, backwards on an Ultra, which is the one
/// where the choice is worth 75% end to end.
///
/// So it is measured, the same way the batch size is: a placement that has not
/// been tried is tried on the next load, what a transcription cost per window is
/// recorded against it, and the best is used from then on. A machine converges
/// in as many launches as there are candidates and stays converged.
///
/// It is measured over a whole transcription and not, like Uhm's and Clear's
/// placements, off a few dispatches at load - because this stage does not run
/// alone. Decode overlaps the encoder, so on the CPU it runs beside engine work
/// and on the engine it queues behind it, and an isolated dispatch cannot see
/// the difference. On an M5 the isolated cost says the engine by a wide margin,
/// 1.48 ms a dispatch against 2.53, while a full run says the CPU by 9% - 433
/// RTFx against 398. The cheap probe would pick the slower machine.
///
/// Only M-series silicon measures at all - see `Placement.explores`. The engine
/// wins on a phone anyway, by 10% (309 RTFx against 280), and it is the
/// placement every other stage there already uses.
///
/// The GPU is not a candidate. It is a little faster than the CPU on an Ultra
/// (564 RTFx against 545) and catastrophic elsewhere - an M1 measures 104
/// against 244 - and unlike the CPU it has been seen to move a token of the
/// transcript. Two candidates keep the exploration to one extra launch.
enum DecodePlacement {

    static let candidates: [(name: String, units: MLComputeUnits)] = Placement.explores
        ? [("ane", .cpuAndNeuralEngine), ("cpu", .cpuOnly)]
        : [("ane", .cpuAndNeuralEngine)]

    /// Whether a placement is still untried, which is what decides the order
    /// the two learned axes run in.
    ///
    /// They cannot be learned at once. Both are measured by timing a whole
    /// transcription, so a run charged to the CPU while the block size happens
    /// to be exploring is being timed against a different pipeline than the run
    /// charged to the engine, and the slower block size lands on whichever
    /// placement drew it. Measured here: interleaved, an M5 recorded the engine
    /// 7% faster and settled at 397 RTFx, where pinning the CPU gets 440.
    ///
    /// So the placement is settled first, at a block of one, and the block size
    /// is explored afterwards underneath the winner. Two runs then five, rather
    /// than ten to cover both axes together.
    static func exploring(model: String) -> Bool {
        guard ProcessInfo.processInfo.environment["VOZ_DEC_UNITS"] == nil else { return false }
        let measured = Measurements.read(model: model, axis: axis)
        return candidates.contains { measured[$0.name] == nil }
    }

    /// The placement to load the decode step with. `VOZ_DEC_UNITS` pins it.
    static func next(model: String) -> (name: String, units: MLComputeUnits) {
        if let pinned = ProcessInfo.processInfo.environment["VOZ_DEC_UNITS"]?.lowercased(),
           let candidate = candidates.first(where: { $0.name == pinned }) {
            return candidate
        }
        let measured = Measurements.read(model: model, axis: axis)
        if let untried = candidates.first(where: { measured[$0.name] == nil }) { return untried }
        // The engine unless something else is clearly better. Clearly, because
        // these samples come from different runs: a phone measured the CPU 1.7%
        // faster across launches and 10% slower when the two were pinned and
        // compared back to back, which is thermal drift outvoting the thing
        // being measured. A margin large enough to clear that drift keeps the
        // engine - the placement that is right on every machine but one, and the
        // one that costs the least power - unless the difference is real. An M3
        // Ultra measures the CPU 29% faster and moves; an M1 measures 0.7% and
        // does not.
        let engine = candidates[0]
        let baseline = measured[engine.name] ?? .greatestFiniteMagnitude
        return candidates.dropFirst()
            .first { (measured[$0.name] ?? .greatestFiniteMagnitude) < baseline * 0.95 }
            ?? engine
    }

    /// What a transcription cost per window at this placement, end to end.
    static func record(model: String, placement: String, secondsPerWindow: Double) {
        guard ProcessInfo.processInfo.environment["VOZ_DEC_UNITS"] == nil else { return }
        Measurements.record(model: model, axis: axis, value: placement,
                            secondsPerItem: secondsPerWindow)
    }

    private static let axis = "voz-decode-placement"
}
#endif
