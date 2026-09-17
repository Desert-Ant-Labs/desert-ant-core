import Foundation
#if canImport(Metal)
import Metal
#endif

/// Which processor a model runs on, decided by measuring this machine.
///
/// `.all` is not a shortcut to the best device, it is Core ML guessing, and it
/// guesses badly often enough to matter: over ten minutes of speech on an M3
/// Ultra, Uhm's detector runs at 626 RTFx at `.all` and 1323 pinned to the GPU.
/// Nor is the answer a property of the model alone - the same detector gains
/// 2.1x from the GPU on an Ultra and 1.2x on an M5 - or of the platform, since
/// two Macs of one family can want opposite placements.
///
/// So a placement that has not been tried is tried on the next load, what the
/// run cost per item is recorded against it, and the best is used from then on.
///
/// Two rules keep this honest:
///
/// - The first candidate is the incumbent, and it keeps ties. Samples come from
///   different runs, so a thermally variable device can rank two placements
///   backwards by a few percent; a margin large enough to clear that drift means
///   nothing moves unless the difference is real.
/// - The caller passes the candidates. Placement changes output - Voz's encoder
///   transcribes differently on the GPU, and Clear's enhancement differs by
///   fp16 rounding - so which placements are *allowed* is a correctness question
///   settled off the device, and only the ranking is measured on it.
public enum Placement {

    /// Whether this device should spend anything looking for a better placement.
    ///
    /// A phone should not. Its GPU is 5 to 10 times slower than its engine for
    /// every model in this package and is drawing the screen off a battery
    /// while it does it, so there is no candidate worth the look - measured on
    /// an iPhone 16 Pro, Uhm runs 180 RTFx on the engine and 154 on the GPU,
    /// Clear 350 against 60.
    ///
    /// An iPad should. It is the one device class here with no measurements at
    /// all, and it is not a big phone: an M-series iPad carries a desktop GPU,
    /// and on the two desktops of that size the GPU wins Uhm by 12% on an M1 and
    /// 33% on an M5. Guessing from the iPhone would be assuming a phone result
    /// about a machine with different silicon, which is the mistake this whole
    /// mechanism exists to stop making. A probe costs under a second, once.
    public static var explores: Bool {
        #if canImport(Metal) && !targetEnvironment(simulator)
        return MTLCreateSystemDefaultDevice()?.name.hasPrefix("Apple M") == true
        #else
        return false
        #endif
    }

    /// How much better a challenger must measure to displace the incumbent.
    private static let margin = 0.95

    public static func next(model: String,
                            candidates: [(name: String, units: ComputeUnits)],
                            override: String? = nil) -> (name: String, units: ComputeUnits) {
        guard let incumbent = candidates.first else { return ("all", .all) }
        // One candidate is not a decision, so do not read a file to make it.
        guard candidates.count > 1 else { return incumbent }
        if let override, let pinned = candidates.first(where: { $0.name == override }) {
            return pinned
        }
        var measured = Measurements.read(model: model, axis: axis)
        // An untried placement is measured here, off a few synthetic dispatches,
        // rather than by handing it a run: the cost of learning should not grow
        // with the length of the file the user happened to open first.
        #if canImport(CoreML)
        for candidate in candidates where measured[candidate.name] == nil {
            guard let cost = PlacementProbe.dispatchCost(modelPath: model,
                                                         units: candidate.units) else { continue }
            Measurements.record(model: model, axis: axis, value: candidate.name,
                                secondsPerItem: cost)
            measured[candidate.name] = cost
        }
        #endif
        return select(candidates: candidates, measured: measured)
    }

    /// Kept separate from probing so ordering and the incumbent margin can be
    /// checked without loading a model or touching the machine's cache.
    static func select(candidates: [(name: String, units: ComputeUnits)],
                       measured: [String: Double]) -> (name: String, units: ComputeUnits) {
        guard let incumbent = candidates.first else { return ("all", .all) }
        let measured = measured.filter { $0.value.isFinite && $0.value > 0 }
        guard measured[incumbent.name] != nil else { return incumbent }
        let baseline = measured[incumbent.name] ?? .greatestFiniteMagnitude
        let fastest = candidates.dropFirst().min {
            (measured[$0.name] ?? .greatestFiniteMagnitude)
                < (measured[$1.name] ?? .greatestFiniteMagnitude)
        }
        guard let fastest, let cost = measured[fastest.name], cost < baseline * margin
        else { return incumbent }
        return fastest
    }

    /// Whether there is anything to learn, which there is not when the caller
    /// offers one placement - a phone pins the engine and never measures.
    public static func measures(candidates: [(name: String, units: ComputeUnits)]) -> Bool {
        candidates.count > 1
    }

    /// What a run cost per item at this placement.
    public static func record(model: String, placement: String, secondsPerItem: Double) {
        Measurements.record(model: model, axis: axis, value: placement,
                            secondsPerItem: secondsPerItem)
    }

    private static let axis = "placement"
}
