#if canImport(CoreML)
import CoreML
import Foundation

/// The loaded model on Apple platforms: three Core ML programs plus the
/// host-side tables, behind the ``VozEngine`` seam the shared pipeline drives.
final class Assets: VozEngine {
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

    // The preallocated I/O (see Buffers.swift for why float16 and why
    // preallocated). `melBuffer` and `padMask` never cross the engine seam:
    // the mel output only exists to feed the encoder, and pad_mask is all ones
    // forever - zeroing the convolution input over padded frames makes those
    // frames explode through the BatchNorm that follows, until their attention
    // scores overpower the additive mask and silence the whole utterance.
    // Masking attention alone (keyBias) is enough.
    private let rowsBuffer: Buffer
    private let melOut: Buffer
    private let keyBiasBuffer: Buffer
    private let padMask: Buffer
    private let melMaskBuffer: Buffer
    private let encOutBuffer: Buffer
    private let embedBuffer: Buffer
    private let hInBuffer: Buffer
    private let cInBuffer: Buffer
    private let encStepBuffer: Buffer
    private let logitsOutBuffer: Buffer
    private let hOutBuffer: Buffer
    private let cOutBuffer: Buffer

    private let melProvider: MLDictionaryFeatureProvider
    private let encoderProvider: MLDictionaryFeatureProvider
    private let stepProvider: MLDictionaryFeatureProvider
    private let melOptions = MLPredictionOptions()
    private let encoderOptions = MLPredictionOptions()
    private let stepOptions = MLPredictionOptions()

    var rows: EngineBuffer<Element> { rowsBuffer.view }
    var melMask: EngineBuffer<Element> { melMaskBuffer.view }
    var keyBias: EngineBuffer<Element> { keyBiasBuffer.view }
    var encOut: EngineBuffer<Element> { encOutBuffer.view }
    var embed: EngineBuffer<Element> { embedBuffer.view }
    var hIn: EngineBuffer<Element> { hInBuffer.view }
    var cIn: EngineBuffer<Element> { cInBuffer.view }
    var encStep: EngineBuffer<Element> { encStepBuffer.view }
    var logitsOut: EngineBuffer<Element> { logitsOutBuffer.view }
    var hOut: EngineBuffer<Element> { hOutBuffer.view }
    var cOut: EngineBuffer<Element> { cOutBuffer.view }

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

        let mlConfiguration = MLModelConfiguration()
        mlConfiguration.computeUnits = computeUnits
        func load(_ name: String) throws -> MLModel {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VozError.invalidModel("missing \(name) in \(directory.path)")
            }
            return try MLModel(contentsOf: url, configuration: mlConfiguration)
        }
        mel = try load(VozModel.mel)
        encoder = try load(VozModel.encoder)
        decodeStep = try load(VozModel.decodeStep)

        guard let embedInput = decodeStep.modelDescription.inputDescriptionsByName["embed"],
              let constraint = embedInput.multiArrayConstraint else {
            throw VozError.invalidModel("decode step is missing its embed input")
        }
        decodeLanes = constraint.shape[0].intValue
        guard decodeLanes > 0 else {
            throw VozError.invalidModel("decode step declares no lanes")
        }

        let c = configuration
        let lanes = decodeLanes
        let hidden = c.predLayers * c.predHidden
        rowsBuffer = try Buffer([1, c.hopLength, 1, c.nRows])
        melOut = try Buffer([1, c.nMels, 1, c.validFrames])
        keyBiasBuffer = try Buffer([1, c.encFrames, 1, 1])
        padMask = try Buffer([1, 1, 1, c.encFrames])
        melMaskBuffer = try Buffer([1, 1, 1, c.validFrames])
        encOutBuffer = try Buffer([1, c.jointHidden, 1, c.encFrames])
        embedBuffer = try Buffer([lanes, c.predHidden, 1, 1])
        hInBuffer = try Buffer([lanes, hidden, 1, 1])
        cInBuffer = try Buffer([lanes, hidden, 1, 1])
        encStepBuffer = try Buffer([lanes, c.jointHidden, 1, c.decodeWidth])
        logitsOutBuffer = try Buffer([lanes, c.vocabSize + 1 + c.durations.count, 1, c.decodeWidth])
        hOutBuffer = try Buffer([lanes, hidden, 1, 1])
        cOutBuffer = try Buffer([lanes, hidden, 1, 1])

        padMask.ptr.update(repeating: 1, count: padMask.count)

        melProvider = try MLDictionaryFeatureProvider(dictionary: [
            "audio_rows": MLFeatureValue(multiArray: rowsBuffer.array),
            "mel_mask": MLFeatureValue(multiArray: melMaskBuffer.array)])
        encoderProvider = try MLDictionaryFeatureProvider(dictionary: [
            "mel": MLFeatureValue(multiArray: melOut.array),
            "key_bias": MLFeatureValue(multiArray: keyBiasBuffer.array),
            "pad_mask": MLFeatureValue(multiArray: padMask.array)])
        stepProvider = try MLDictionaryFeatureProvider(dictionary: [
            "embed": MLFeatureValue(multiArray: embedBuffer.array),
            "h_in": MLFeatureValue(multiArray: hInBuffer.array),
            "c_in": MLFeatureValue(multiArray: cInBuffer.array),
            "enc_step": MLFeatureValue(multiArray: encStepBuffer.array)])
        // Write predictions straight into our own storage instead of letting
        // Core ML allocate a result per call.
        melOptions.outputBackings = ["mel": melOut.array]
        encoderOptions.outputBackings = ["enc_proj": encOutBuffer.array]
        stepOptions.outputBackings = [
            "logits": logitsOutBuffer.array, "h_out": hOutBuffer.array, "c_out": cOutBuffer.array]
    }

    func runMel() throws { _ = try mel.prediction(from: melProvider, options: melOptions) }
    func runEncoder() throws {
        _ = try encoder.prediction(from: encoderProvider, options: encoderOptions)
    }
    func runDecodeStep() throws {
        _ = try decodeStep.prediction(from: stepProvider, options: stepOptions)
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
