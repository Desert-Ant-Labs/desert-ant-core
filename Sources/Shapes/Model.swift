import DesertAnt

/// One recognition: `Model` resamples the stroke, runs the classifier, checks
/// the kind's gates, fits the shape, and snaps the shape per `Options`.
final class Model: @unchecked Sendable {
    private let session: any InferenceSession
    private let meta: ShapeMeta

    /// A stroke shorter than this, in canvas units, is a tap.
    static let minimumLength = 6.0

    init(assets: ModelAssets) throws {
        session = assets.session
        meta = try ShapeMeta(json: assets.metaJSON)
    }

    func recognize(points: [Point], options: Options) async throws -> Shape? {
        guard points.count >= 2, Preprocess.length(points) >= Self.minimumLength else { return nil }
        let (probs, head) = try await outputs(points)
        var top = 0
        for i in probs.indices where probs[i] > probs[top] { top = i }
        guard top < meta.classes.count, !meta.rejects.contains(top), let kind = meta.classes[top] else {
            return nil
        }
        let gate = meta.gates[kind] ?? ShapeMeta.Gate()
        let confidence = Double(probs[top])
        guard confidence >= gate.conf, confidence >= options.minimumConfidence else { return nil }
        let fit = Fitter.fit(kind, points: points, head: head, straightTolerance: meta.straightTolerance)
        guard fit.residual <= gate.resid else { return nil }
        let shape = Snapping.apply(fit.shape, rotation: options.rotation)
        // The classifier's `line` class fits as a line or a curve, so the kinds
        // filter checks the fitted shape.
        return options.kinds.contains(shape.kind) ? shape : nil
    }

    /// One forward pass: class probabilities and per-point arrowhead probabilities.
    func outputs(_ points: [Point]) async throws -> ([Float], [Float]) {
        let n = meta.pointCount
        let input = Preprocess.modelInput(points, count: n)
        let outputs = try await session.run(
            inputs: ["points": Tensor(float32: input, shape: [1, n, 2])],
            outputs: ["probs", "head"])
        guard outputs.count == 2,
              let probs = outputs[0].float32Values, probs.count == meta.classes.count,
              let head = outputs[1].float32Values, head.count == n else {
            throw ShapesError.predictionFailed
        }
        return (probs, head)
    }
}
