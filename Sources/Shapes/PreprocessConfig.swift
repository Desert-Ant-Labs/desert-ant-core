/// Tunables + frozen constants for the stroke preprocessor.
///
/// The defaults match the trained model's `config.json` exactly. The SAME values
/// must be used at training-data generation, training, and inference on every
/// platform — any divergence silently destroys accuracy.
struct PreprocessConfig: Sendable {
    /// Arc-length spacing in normalized units (~0.02 -> ~50 points per stroke).
    var spacing: Double
    /// Frozen z-score mean for the distance channel.
    var distMean: Double
    /// Frozen z-score std for the distance channel.
    var distStd: Double
    /// Append the optional 4th turning-angle (curvature) channel.
    var addCurvature: Bool
    /// Reject strokes with fewer than this many unique points.
    var minPoints: Int
    /// Reject strokes whose total length is below this.
    var minTotalLength: Double
    /// Consecutive raw points closer than this are treated as duplicates.
    var dedupeEpsilon: Double

    init(
        spacing: Double = 0.02,
        distMean: Double = 0.01927179223622642,
        distStd: Double = 0.0020772687597318262,
        addCurvature: Bool = false,
        minPoints: Int = 2,
        minTotalLength: Double = 1e-6,
        dedupeEpsilon: Double = 1e-9
    ) {
        self.spacing = spacing
        self.distMean = distMean
        self.distStd = distStd
        self.addCurvature = addCurvature
        self.minPoints = minPoints
        self.minTotalLength = minTotalLength
        self.dedupeEpsilon = dedupeEpsilon
    }

    /// Number of feature channels per point (3, or 4 with curvature).
    var channelCount: Int { addCurvature ? 4 : 3 }
}

/// Raised when a stroke is too short / too small to be meaningful.
struct DegenerateStrokeError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { "DegenerateStrokeError: \(message)" }
}
