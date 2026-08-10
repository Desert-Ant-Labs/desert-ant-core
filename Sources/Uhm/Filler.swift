import DesertAnt

/// A filler span produced by the internal pipeline (frame detector or type
/// classifier). Mapped to the public `Uhm.Detection` in `Uhm.analyze`.
struct Filler: Sendable, Equatable {
    /// Producing-stage label: `"filler"` from the frame detector, or a type
    /// such as `"uh"`/`"um"` from the type classifier.
    let label: String
    let start: Double
    let end: Double
    let confidence: Double

    var duration: Double { end - start }
}
