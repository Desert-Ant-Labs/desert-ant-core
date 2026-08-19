/// A single preprocessed stroke point: the per-point feature vector fed to the
/// model. Channel order is fixed everywhere: `[distance, cosTheta, sinTheta]`
/// (plus `curvature` when enabled), matching the Python reference.
struct StrokePoint: Equatable, Sendable {
    /// Z-scored distance from the previous resampled point.
    let distance: Float
    /// Unit direction from the previous point: cosine component.
    let cosTheta: Float
    /// Unit direction from the previous point: sine component.
    let sinTheta: Float
    /// Turning angle (wrapped to (-pi, pi]); `0` when the curvature channel is disabled.
    let curvature: Float

    init(distance: Float, cosTheta: Float, sinTheta: Float, curvature: Float = 0) {
        self.distance = distance
        self.cosTheta = cosTheta
        self.sinTheta = sinTheta
        self.curvature = curvature
    }

    /// Channels in fixed model order. `count` is 3, or 4 with curvature.
    func channels(curvature includeCurvature: Bool) -> [Float] {
        includeCurvature
            ? [distance, cosTheta, sinTheta, curvature]
            : [distance, cosTheta, sinTheta]
    }
}
