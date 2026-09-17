#if canImport(CoreML)
import CoreML
import Foundation

/// Measures what a placement costs without spending a run on it.
///
/// The obvious way to learn where a model belongs is to run it somewhere and
/// time it, but that charges the whole file for the answer: exploring three
/// placements over two hours of audio on an M3 Ultra costs about 28 seconds,
/// and the cost grows with every file the user hands over. Nothing about the
/// answer needs a whole file, though - placements differ in what a single
/// dispatch costs, so a handful of dispatches on synthetic input settles it in
/// a time that does not depend on the input at all.
///
/// The two constants below are measured rather than chosen. On an M5, dispatch
/// cost is flat from the second one onward (uhm: 122.8, 81.8, 79.0, 80.5, 80.8
/// ms), so one warmup covers the pipeline setup the first dispatch pays for.
/// After that a single sample is within 0.7% of a twenty-dispatch median on
/// every model and placement tried, which is far inside the margin a placement
/// has to clear, so two samples are taken and the faster kept.
///
/// That this predicts the real ranking is not assumed. Against full ten-minute
/// runs it agrees on every machine and model measured - M1, M5 and M3 Ultra,
/// Uhm and Clear, six for six - including the one case where the GPU loses
/// (Clear on an M1: 17.9 ms at `.all` against 27.9 on the GPU, and the full run
/// agrees at 250 RTFx against 171).
enum PlacementProbe {

    private static let warmupDispatches = 1
    private static let timedDispatches = 2

    /// Seconds per dispatch at this placement, or nil if the model will not
    /// load there - a placement that cannot run is not a placement.
    static func dispatchCost(modelPath: String, units: ComputeUnits) -> Double? {
        autoreleasepool {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = units.mlComputeUnits
            guard let model = try? MLModel(contentsOf: URL(fileURLWithPath: modelPath),
                                           configuration: configuration),
                  let input = try? syntheticInput(for: model) else { return nil }
            for _ in 0..<warmupDispatches {
                guard (try? model.prediction(from: input)) != nil else { return nil }
            }
            var best = Double.greatestFiniteMagnitude
            for _ in 0..<timedDispatches {
                let mark = ContinuousClock.now
                guard (try? model.prediction(from: input)) != nil else { return nil }
                let duration = mark.duration(to: .now).components
                let elapsed = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                best = min(best, elapsed)
            }
            return best
        }
    }

    /// Input of the shape the model declares. The values are random rather than
    /// zero so nothing downstream can take a shortcut through them.
    private static func syntheticInput(for model: MLModel) throws -> MLFeatureProvider {
        var features: [String: MLFeatureValue] = [:]
        for (name, description) in model.modelDescription.inputDescriptionsByName {
            guard let constraint = description.multiArrayConstraint else { continue }
            let shape = constraint.shape.map { max(1, $0.intValue) }
            let array = try MLMultiArray(shape: shape as [NSNumber],
                                         dataType: constraint.dataType)
            array.withUnsafeMutableBytes { raw, _ in
                guard let base = raw.baseAddress else { return }
                switch constraint.dataType {
                case .float32:
                    let values = base.bindMemory(to: Float.self, capacity: raw.count / 4)
                    for i in 0..<(raw.count / 4) { values[i] = Float.random(in: -1...1) }
                case .float16:
                    let values = base.bindMemory(to: Float16.self, capacity: raw.count / 2)
                    for i in 0..<(raw.count / 2) { values[i] = Float16.random(in: -1...1) }
                default:
                    memset(base, 0, raw.count)
                }
            }
            features[name] = MLFeatureValue(multiArray: array)
        }
        return try MLDictionaryFeatureProvider(dictionary: features)
    }
}
#endif
