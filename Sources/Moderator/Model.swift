import DesertAnt

/// Crops an image, scores every crop through the shared `InferenceSession`
/// (Core ML | LiteRT | JS host, chosen by the core), and keeps the per-head max.
/// Normalization is inside the model, so a crop goes in as raw pixels.
final class Model: Sendable {
    private let session: any InferenceSession

    /// Head order of the graph's `scores` output.
    private static let heads = 5

    init(assets: ModelAssets) {
        session = assets.session
    }

    func regions(for image: ImagePixels, quality: Quality) async throws -> Regions {
        let crops = try await Preprocess.crops(image, quality: quality)
        let peaks = Peaks(count: crops.count)
        let session = self.session
        try await ParallelRuns.run(count: crops.count, sessions: [session]) { i, session in
            try Task.checkCancellation()
            await peaks.set(i, try await Self.score(crops[i], session: session))
        }
        let p = await peaks.max()
        return Regions(nipples: p[0], genitals: p[1], buttocks: p[2], nude: p[3], sexAct: p[4])
    }

    private static func score(_ rgb: [UInt8], session: any InferenceSession) async throws -> [Double] {
        let side = Preprocess.side
        let pixels = Tensor(float32: rgb.map(Float.init), shape: [1, side, side, 3])
        let out = try await session.run(inputs: ["image": pixels], outputs: ["scores"])
        guard let scores = out.first?.float32Values, scores.count == heads,
              scores.allSatisfy(\.isFinite) else { throw ModeratorError.predictionFailed }
        return scores.map(Double.init)
    }
}

/// One slot per crop, filled by concurrent runs.
private actor Peaks {
    private var rows: [[Double]]

    init(count: Int) { rows = Array(repeating: [], count: count) }

    func set(_ index: Int, _ scores: [Double]) { rows[index] = scores }

    func max() -> [Double] {
        (0..<5).map { h in rows.map { $0[h] }.max() ?? 0 }
    }
}
