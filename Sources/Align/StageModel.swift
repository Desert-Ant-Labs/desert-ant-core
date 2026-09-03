#if canImport(CoreML)
import CoreML
import Foundation

/// Runs one cascade stage (batch of 16) and returns the softmax-expected frame position
/// for each item. Inputs: mel [16,1,40,W] float32, text_bytes [16,32] int32,
/// language_id [16] int32, boundary_kind [16] int32.
struct StagePrediction {
    let isValid: Bool
    let position: Double
    let entropy: Double
    let normalizedDeviation: Double
    let maxProbability: Double
    let probabilityMargin: Double
    let edgeProbability: Double
}

final class StageModel {
    /// Overridden by the parity tests so a recorded fixture reproduces on any machine.
    nonisolated(unsafe) static var computeUnits: MLComputeUnits = .cpuAndNeuralEngine

    let model: MLModel
    let width: Int
    private let outputName: String

    init(url: URL, width: Int) throws {
        let cfg = MLModelConfiguration()
        // The Neural Engine in production. Tests pin this to .cpuOnly: Core ML's ANE and CPU
        // paths do not agree bit for bit in float16, and on an input the model is unsure about
        // the softmax-expectation decode turns that into tens of milliseconds. CI runners are
        // virtualised and have no ANE, so a fixture recorded on a developer's Mac could never
        // match one recorded there.
        cfg.computeUnits = StageModel.computeUnits
        self.model = try MLModel(contentsOf: url, configuration: cfg)
        self.width = width
        self.outputName = model.modelDescription.outputDescriptionsByName.keys.first!
    }

    /// Returns decoded position and uncertainty statistics for up to 16 items.
    func predictions(mel: [[Float]], bytes: [[Int32]], langs: [Int32], kinds: [Int32]) throws -> [StagePrediction] {
        let n = mel.count
        precondition(n <= 16)
        let melArr = try MLMultiArray(shape: [16, 1, 40, NSNumber(value: width)], dataType: .float16)
        let byteArr = try MLMultiArray(shape: [16, 32], dataType: .int32)
        let langArr = try MLMultiArray(shape: [16], dataType: .int32)
        let kindArr = try MLMultiArray(shape: [16], dataType: .int32)
        let melPtr = melArr.dataPointer.bindMemory(to: Float16.self, capacity: melArr.count)
        let bytePtr = byteArr.dataPointer.bindMemory(to: Int32.self, capacity: byteArr.count)
        let langPtr = langArr.dataPointer.bindMemory(to: Int32.self, capacity: langArr.count)
        let kindPtr = kindArr.dataPointer.bindMemory(to: Int32.self, capacity: kindArr.count)
        let crop = 40 * width
        for i in 0..<16 {
            let s = min(i, n - 1)  // pad tail rows by repeating the last valid item
            for j in 0..<crop { melPtr[i * crop + j] = Float16(mel[s][j]) }
            for j in 0..<32 { bytePtr[i * 32 + j] = bytes[s][j] }
            langPtr[i] = langs[s]
            kindPtr[i] = kinds[s]
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "mel": melArr, "text_bytes": byteArr, "language_id": langArr, "boundary_kind": kindArr,
        ])
        let out = try model.prediction(from: input)
        let logits = out.featureValue(for: outputName)!.multiArrayValue!  // [16, width] float16
        let lp = logits.dataPointer.bindMemory(to: Float16.self, capacity: logits.count)
        let sB = logits.strides[0].intValue, sF = logits.strides[1].intValue
        var result: [StagePrediction] = []
        result.reserveCapacity(n)
        for i in 0..<n {
            // Softmax statistics over frames, respecting MLMultiArray strides.
            var maxv = -Float.greatestFiniteMagnitude
            for f in 0..<width { maxv = max(maxv, Float(lp[i * sB + f * sF])) }
            var weights = [Double](repeating: 0, count: width)
            var sum = 0.0, weighted = 0.0
            for f in 0..<width {
                let value = Double(exp(Float(lp[i * sB + f * sF]) - maxv))
                weights[f] = value
                sum += value
                weighted += value * Double(f)
            }
            let mean = weighted / sum
            var variance = 0.0, entropy = 0.0, edge = 0.0
            var first = 0.0, second = 0.0
            for f in 0..<width {
                let probability = weights[f] / sum
                let delta = Double(f) - mean
                variance += probability * delta * delta
                if probability > 0 { entropy -= probability * log(probability) }
                if f < 5 || f >= width - 5 { edge += probability }
                if probability > first {
                    second = first
                    first = probability
                } else if probability > second {
                    second = probability
                }
            }
            result.append(StagePrediction(
                isValid: true,
                position: mean,
                entropy: entropy / log(Double(width)),
                normalizedDeviation: sqrt(variance) / Double(width),
                maxProbability: first,
                probabilityMargin: first - second,
                edgeProbability: edge
            ))
        }
        return result
    }

    func expectedPositions(mel: [[Float]], bytes: [[Int32]], langs: [Int32], kinds: [Int32]) throws -> [Double] {
        try predictions(mel: mel, bytes: bytes, langs: langs, kinds: kinds).map(\.position)
    }
}
#endif
