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
    ///
    /// Held as the mapped file rather than an array of its contents: the bytes
    /// on disk are already exactly the layout the decode reads, so there is
    /// nothing to convert. See ``withEmbedding(_:)``.
    private let embeddingData: Data
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
            throw VozError.invalidModel("vocabulary is smaller than the model's vocab size")
        }

        let raw = try Data(contentsOf: directory.appendingPathComponent("embedding.f16"),
                           options: .mappedIfSafe)
        let expected = (configuration.vocabSize + 1) * configuration.predHidden
        guard raw.count == expected * MemoryLayout<Element>.size else {
            throw VozError.invalidModel(
                "embedding.f16 has \(raw.count) bytes, expected \(expected * 2)")
        }
        embeddingData = raw

        func options(_ units: MLComputeUnits) -> MLModelConfiguration {
            let options = MLModelConfiguration()
            options.computeUnits = units
            return options
        }
        func load(_ name: String, _ options: MLModelConfiguration) throws -> MLModel {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VozError.invalidModel("missing \(name) in \(directory.path)")
            }
            return try MLModel(contentsOf: url, configuration: options)
        }
        let asked = options(computeUnits)
        mel = try load(VozModel.mel, asked)
        encoder = try load(VozModel.encoder, asked)
        // The decode step is small and dispatch-bound, and it runs beside the
        // encoder rather than after it, so on the Neural Engine it queues
        // behind engine work while a performance core sits idle. Measured over
        // ten minutes of speech: an M3 Ultra goes from 181 to 310 RTFx, an M5
        // from 398 to 439, an M1 from 242 to 251. A phone measures the other
        // way (309 against 280) and keeps the engine.
        decodeStep = try load(VozModel.decodeStep,
                              Silicon.isMSeries ? options(.cpuOnly) : asked)

        guard let embed = decodeStep.modelDescription.inputDescriptionsByName["embed"],
              let constraint = embed.multiArrayConstraint else {
            throw VozError.invalidModel("decode step is missing its embed input")
        }
        decodeLanes = constraint.shape[0].intValue
        guard decodeLanes > 0 else {
            throw VozError.invalidModel("decode step declares no lanes")
        }
    }

    /// The embedding table, in the mapped file's own memory.
    ///
    /// Reading it in place rather than materializing it: the file is 10.5 MB of
    /// float16 in row-major order, which is what a decode step wants, so a copy
    /// buys nothing. Building an array of it cost a 5,243,520-iteration loop
    /// that an unoptimized build (a dependency's default) runs one element at a
    /// time, and faulted the whole table in from disk when a decode reads only
    /// the rows it emits. Measured on an M-series Mac, that loop was 620 ms of
    /// the 780 ms load.
    ///
    /// Binding is well formed rather than lucky: a mapping starts on a page
    /// boundary, and `Data` allocates with more alignment than a two byte
    /// element needs, so neither backing can land this odd.
    func withEmbedding<T>(_ body: (UnsafeBufferPointer<Element>) throws -> T) rethrows -> T {
        try embeddingData.withUnsafeBytes { try body($0.bindMemory(to: Element.self)) }
    }
}
#endif
