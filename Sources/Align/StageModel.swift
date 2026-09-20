import Inference
import RealModule

struct StagePrediction {
    let position: Double
    let entropy: Double
    let normalizedDeviation: Double
    let maxProbability: Double
    let probabilityMargin: Double
    let edgeProbability: Double
}

/// One cascade stage at a fixed batch of 16; the tail rows repeat the last valid item.
final class StageModel: Sendable {
    static let batch = 16
    let session: any InferenceSession
    let width: Int
    let outputName: String

    init(session: any InferenceSession, width: Int, outputName: String) {
        self.session = session
        self.width = width
        self.outputName = outputName
    }

    func predictions(mel: [[Float]], bytes: [[Int32]], langs: [Int32], kinds: [Int32]) async throws -> [StagePrediction] {
        let n = mel.count, b = Self.batch, crop = 40 * width
        precondition(n > 0 && n <= b)
        var melFlat = [Float](repeating: 0, count: b * crop)
        var byteFlat = [Int32](repeating: 0, count: b * 32)
        var langFlat = [Int32](repeating: 0, count: b), kindFlat = [Int32](repeating: 0, count: b)
        for i in 0..<b {
            let s = min(i, n - 1)
            for j in 0..<crop { melFlat[i * crop + j] = mel[s][j] }
            for j in 0..<32 { byteFlat[i * 32 + j] = bytes[s][j] }
            langFlat[i] = langs[s]; kindFlat[i] = kinds[s]
        }
        let out = try await session.run(inputs: [
            "mel": Tensor(float32: melFlat, shape: [b, 1, 40, width]),
            "text_bytes": Tensor(int32: byteFlat, shape: [b, 32]),
            "language_id": Tensor(int32: langFlat, shape: [b]),
            "boundary_kind": Tensor(int32: kindFlat, shape: [b]),
        ], outputs: [outputName])
        guard let logits = out.first?.float32Values, logits.count == b * width else {
            throw InferenceError.runFailed("align: expected \(outputName) as [\(b), \(width)] float32")
        }
        var result: [StagePrediction] = []
        result.reserveCapacity(n)
        for i in 0..<n {
            let row = logits[(i * width)..<((i + 1) * width)]
            var maxv = -Float.greatestFiniteMagnitude
            for v in row { maxv = max(maxv, v) }
            var weights = [Double](repeating: 0, count: width)
            var sum = 0.0, weighted = 0.0
            for f in 0..<width {
                let value = Double(Float.exp(row[row.startIndex + f] - maxv))
                weights[f] = value; sum += value; weighted += value * Double(f)
            }
            let mean = weighted / sum
            var variance = 0.0, entropy = 0.0, edge = 0.0, first = 0.0, second = 0.0
            for f in 0..<width {
                let p = weights[f] / sum, d = Double(f) - mean
                variance += p * d * d
                if p > 0 { entropy -= p * Double.log(p) }
                if f < 5 || f >= width - 5 { edge += p }
                if p > first { second = first; first = p } else if p > second { second = p }
            }
            result.append(StagePrediction(
                position: mean, entropy: entropy / Double.log(Double(width)),
                normalizedDeviation: variance.squareRoot() / Double(width),
                maxProbability: first, probabilityMargin: first - second, edgeProbability: edge))
        }
        return result
    }
}
