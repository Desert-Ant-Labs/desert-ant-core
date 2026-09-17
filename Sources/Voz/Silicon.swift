#if canImport(CoreML)
import Metal

/// Which line of Apple silicon this is.
///
/// The decode step's placement and its overlap both turn on this and nothing
/// else: an M-series part has performance cores to spare for a stage that runs
/// beside the encoder, where an A-series part has two and a screen to draw with
/// them. It is a question about the chip rather than the product, so an
/// M-series iPad answers the same as a Mac.
///
/// Metal names the chip - "Apple M1", "Apple M3 Ultra", "Apple A18 Pro GPU" -
/// so the line is the letter after Apple. A machine with no Metal device, which
/// is an Intel Mac or a stripped environment, answers false and keeps the
/// decode wherever the caller asked for it.
enum Silicon {
    static let isMSeries: Bool = {
        MTLCreateSystemDefaultDevice()?.name.hasPrefix("Apple M") ?? false
    }()
}
#endif
