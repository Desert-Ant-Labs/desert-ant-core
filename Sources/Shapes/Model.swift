import DesertAnt

/// The neural stage plus geometry verification: preprocess a stroke into the
/// model's feature vectors, classify it through the shared `InferenceSession`
/// (Core ML | LiteRT | JS host, chosen by the core), then fit and gate the
/// proposed shape. This file only knows shapes' tensor layout; the runtime is
/// oblivious.
final class Model: @unchecked Sendable {
    private let session: any InferenceSession
    private let meta: ShapeMeta
    private let preprocessor: StrokePreprocessor

    /// The Core ML and LiteRT exports share one graph: a fixed 256-length window
    /// of `[distance, cos, sin]` features with a 1/0 validity mask.
    private static let sequenceLength = 256

    init(assets: ModelAssets) throws {
        session = assets.session
        meta = try ShapeMeta(json: assets.metaJSON)
        preprocessor = StrokePreprocessor(config: meta.config)
    }

    /// Recognize a stroke: preprocess, classify, then fit and gate. Returns the
    /// snapped ``Shape``, or `nil` when rejected or degenerate.
    func recognize(points: [Point], options: Options) async throws -> Shape? {
        let features: [StrokePoint]
        do {
            features = try preprocessor.process(points: points)
        } catch is DegenerateStrokeError {
            return nil
        }
        let (index, confidence) = try await classify(features)
        guard index < meta.classOrder.count, let kind = meta.classOrder[index] else {
            return nil  // reject class
        }
        guard let gate = meta.gates[kind] else { return nil }
        if confidence < gate.conf { return nil }
        if confidence < Float(options.minimumConfidence) { return nil }

        let (shape, residual) = Fitter.fit(kind, points: points, snap: options.snap)
        if Float(residual) > gate.resid { return nil }
        return shape
    }

    // MARK: inference

    /// Run the classifier over one stroke's features, returning the top class
    /// index and its probability.
    private func classify(_ features: [StrokePoint]) async throws -> (index: Int, confidence: Float) {
        let probs = try await probabilities(features)
        var bestIndex = 0
        var bestValue = -Float.greatestFiniteMagnitude
        for i in 0..<probs.count where probs[i] > bestValue {
            bestValue = probs[i]
            bestIndex = i
        }
        return (bestIndex, bestValue)
    }

    /// Build the padded-window tensors and read the `probs` output.
    private func probabilities(_ features: [StrokePoint]) async throws -> [Float] {
        let seq = Self.sequenceLength
        var feat = [Float](repeating: 0, count: seq * 3)
        var mask = [Float](repeating: 0, count: seq)
        let n = min(features.count, seq)
        for s in 0..<n {
            let p = features[s]
            feat[s * 3 + 0] = p.distance
            feat[s * 3 + 1] = p.cosTheta
            feat[s * 3 + 2] = p.sinTheta
            mask[s] = 1
        }
        let output = try await session.run(
            inputs: [
                "features": Tensor(float32: feat, shape: [1, seq, 3]),
                "mask": Tensor(float32: mask, shape: [1, seq]),
            ],
            outputs: ["probs"])[0]
        guard let probs = output.float32Values, !probs.isEmpty else {
            throw ShapesError.predictionFailed
        }
        return probs
    }
}
