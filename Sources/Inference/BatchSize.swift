import Foundation

/// How many items to hand a model in one submission.
///
/// There is no right constant, which is what makes this worth deciding at all:
/// a 15 s window fills a Neural Engine on some chips and leaves it idle on
/// others. What decides it is how many engines there are to fill, and Apple's
/// Ultra parts are the only ones with more than one - two dies fused together,
/// each with its own. One submission carrying several windows is how the
/// runtime reaches the second; a window at a time can only ever use the first.
///
/// Ten minutes of speech through Voz, per block width:
///
///                 1     2     4     8    16
///   M1          253   253   252   251   248
///   M5          443   441   437   429   412
///   M3 Ultra    324   439   477   498   490
///
/// Everything with one die is flat and slightly prefers the narrow block, which
/// stages less and hands work to the consumer in finer steps. The two-die
/// machine is not flat at all: it loses a third of its speed at a block of one.
///
/// Three ways of choosing this by measurement were built and thrown away - the
/// fastest submission in isolation (picks the widest, wrongly), a cost model
/// (scored eight and sixteen within 0.1% where the pipeline separates them by
/// 12%), and timing whole transcriptions (right, but bills the user's first
/// files for it). The die count says the same thing for nothing.
public enum BatchSize {

    /// Windows per submission for a stage whose consumer runs underneath it.
    ///
    /// `DAL_BATCH_SIZE` pins it, for repeating the sweep above.
    public static var forOverlappedEncoder: Int {
        if let override = ProcessInfo.processInfo.environment["DAL_BATCH_SIZE"],
           let size = Int(override), size > 0 { return min(size, maximum) }
        let engines = Hardware.current.neuralEngines
        // One engine wants nothing in flight beyond the window it is running:
        // every 16-core machine measured is flat across the widths and prefers
        // the narrow block, which stages less and hands work over in finer
        // steps. Past one engine the block is what reaches the others.
        guard engines >= 2 else { return 1 }
        return min(engines * submissionsPerEngine, maximum)
    }

    /// How deep to keep each engine's queue, which is the part of the Ultra
    /// measurement that is not about the number two.
    ///
    /// The curve there is a plateau rather than a peak - 324, 439, 477, 498,
    /// 490 RTFx at one, two, four, eight and sixteen - so what it says is
    /// "several submissions per engine", not "eight". Two per engine already
    /// takes 96% of the win; four sits at the top; eight gives 2% back,
    /// because past the point where every engine is fed a wider block only
    /// delays the handoff to the consumer.
    ///
    /// Written per engine so a part with more of them scales instead of
    /// starving, which is the failure a constant eight would repeat one
    /// generation later.
    private static let submissionsPerEngine = 4

    /// The widest block any machine will ask for, which is how much staging
    /// storage a caller has to keep: a slot is a mel and an attention bias,
    /// about 400 KB for Voz.
    ///
    /// A ceiling as well as a promise. It is not a measured optimum - nothing
    /// with more than two engines exists to measure - so it caps the
    /// extrapolation above at a width whose staging cost is known.
    public static let maximum = 8
}
