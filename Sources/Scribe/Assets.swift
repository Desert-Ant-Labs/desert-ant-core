#if canImport(CoreML)
import CoreML
import Foundation

/// The loaded model: three Core ML programs plus the host-side tables.
struct Assets {
    let configuration: Configuration
    let vocabulary: [String]
    /// Row-major `[vocab + 1, predHidden]`, already float16 so a decode step
    /// copies a row without converting. The embedding stays outside the graph:
    /// a gather over an 8193 x 640 table has no Neural Engine kernel and is a
    /// table read the host does for free.
    let embedding: [Element]
    let mel: MLModel
    let encoder: MLModel
    let decodeStep: MLModel
    /// Windows decoded per dispatch, read from the model rather than assumed.
    let decodeLanes: Int

    init(directory: URL, computeUnits: MLComputeUnits) throws {
        let decoder = JSONDecoder()
        configuration = try decoder.decode(
            Configuration.self,
            from: try Data(contentsOf: directory.appendingPathComponent("meta.json")))
        try configuration.validate()
        vocabulary = try decoder.decode(
            [String].self,
            from: try Data(contentsOf: directory.appendingPathComponent("vocab.json")))
        guard vocabulary.count >= configuration.vocabSize else {
            throw ScribeError.invalidModel("vocabulary is smaller than the model's vocab size")
        }

        let raw = try Data(contentsOf: directory.appendingPathComponent("embedding.f16"),
                           options: .mappedIfSafe)
        let expected = (configuration.vocabSize + 1) * configuration.predHidden
        guard raw.count == expected * MemoryLayout<Element>.size else {
            throw ScribeError.invalidModel(
                "embedding.f16 has \(raw.count) bytes, expected \(expected * 2)")
        }
        embedding = raw.withUnsafeBytes { buf in
            (0..<expected).map { buf.loadUnaligned(fromByteOffset: $0 * 2, as: Element.self) }
        }

        let mlConfiguration = MLModelConfiguration()
        mlConfiguration.computeUnits = computeUnits
        func load(_ name: String) throws -> MLModel {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ScribeError.invalidModel("missing \(name) in \(directory.path)")
            }
            return try MLModel(contentsOf: url, configuration: mlConfiguration)
        }
        mel = try load(ScribeModel.mel)
        encoder = try load(ScribeModel.encoder)
        decodeStep = try load(ScribeModel.decodeStep)

        guard let embed = decodeStep.modelDescription.inputDescriptionsByName["embed"],
              let constraint = embed.multiArrayConstraint else {
            throw ScribeError.invalidModel("decode step is missing its embed input")
        }
        decodeLanes = constraint.shape[0].intValue
        guard decodeLanes > 0 else {
            throw ScribeError.invalidModel("decode step declares no lanes")
        }
    }
}
#endif
