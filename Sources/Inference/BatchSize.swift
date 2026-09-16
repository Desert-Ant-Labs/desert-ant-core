import Foundation

/// How many items to hand a model in one submission, learned on this machine
/// from the work it actually runs.
///
/// There is no right constant. A 15 s window fills a Neural Engine on some chips
/// and leaves it idle on others, and a machine with two engines wants more in
/// flight than one with a single engine: the best size measured one on an iPhone
/// 16 Pro, one to four on an M1 and an M5, and eight on an M3 Ultra. Any number
/// written here is a guess about every machine nobody measured.
///
/// Two ways of deciding it were tried and thrown away, both because they
/// optimised the wrong thing:
///
/// - Fastest per window, timed on the loaded model at startup. The widest block
///   always wins that, and on an M3 Ultra it chose sixteen and ran the pipeline
///   at 535 RTFx against 608 for eight.
/// - The same timings through a cost model - blocks to fill a group, plus the
///   last one that has nothing to overlap with. Closer, but it scored eight and
///   sixteen within 0.1% of each other where the pipeline separates them by 12%.
///
/// What the pipeline cares about is how long a group takes end to end, with the
/// decode running underneath, and that is a thing it can simply time. So each
/// group reports what its size cost per window, the best time per size is kept
/// in the cache directory, and a size that has never been tried is tried next.
/// A machine converges over its first few transcriptions and stays converged
/// across launches, per model revision and OS build.
#if canImport(Darwin)
import Darwin

public enum BatchSize {

    /// Sizes considered. Powers of two to the point where holding the block
    /// costs more than it can save: sixteen slots is 6 MB of staged mels.
    public static let candidates = [1, 2, 4, 8, 16]

    /// The size to use next: anything untried, else the smallest that is not
    /// meaningfully slower than the best measured. `DAL_BATCH_SIZE` pins it.
    ///
    /// Smallest-within-tolerance rather than fastest, because a wider batch is
    /// not free even when it times the same: it holds more staged input, and it
    /// hands work to the consumer in coarser steps. Where the curve is flat -
    /// an M1 and an M5 measure every size within 1% for Voz's encoder - this
    /// keeps the behaviour the code had before any of this existed.
    public static func next(model: String) -> Int {
        if let override = ProcessInfo.processInfo.environment["DAL_BATCH_SIZE"],
           let size = Int(override), size > 0 { return size }
        let measured = Measurements.read(model: model, axis: axis)
        if let untried = candidates.first(where: { measured[String($0)] == nil }) { return untried }
        guard let best = measured.values.min() else { return 1 }
        let tolerated = best * 1.03
        return candidates.first { (measured[String($0)] ?? .greatestFiniteMagnitude) <= tolerated }
            ?? 1
    }

    /// What a group cost at `size`, per window, including the decode that ran
    /// underneath it. The best time per size is what is kept: a group that
    /// happened to run while the machine was busy should not condemn a size
    /// forever.
    public static func record(model: String, size: Int, secondsPerItem: Double) {
        guard secondsPerItem > 0, ProcessInfo.processInfo.environment["DAL_BATCH_SIZE"] == nil
        else { return }
        // The first measurement after a load is thrown away: it carries the
        // model's first-call costs, and charging those to whichever size went
        // first is how this picked a worse size than the one it replaced.
        guard warmed.mark(model) else { return }
        Measurements.record(model: model, axis: axis, value: String(size),
                            secondsPerItem: secondsPerItem)
    }

    private static let axis = "batch-size"

    /// One discarded measurement per model per process.
    private final class Warmup: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: Set<String> = []
        func mark(_ model: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return !seen.insert(model).inserted
        }
    }
    private static let warmed = Warmup()

}

#else

/// Only Core ML batches, so everywhere else this is the answer the loop already
/// gave: one item per call, nothing measured, nothing cached.
public enum BatchSize {
    public static let candidates = [1]
    public static func next(model: String) -> Int { 1 }
    public static func record(model: String, size: Int, secondsPerItem: Double) {}
}

#endif
