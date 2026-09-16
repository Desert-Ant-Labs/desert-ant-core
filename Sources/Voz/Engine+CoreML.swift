#if canImport(CoreML)
import CoreML
import Foundation

/// The Core ML engine: three compiled programs, driven with preallocated
/// buffers and `outputBackings` so a prediction allocates nothing.
///
/// This is the path the shipping numbers come from, and its shape is load
/// bearing. The feature providers and options are built once at init because
/// the inputs never change identity - only their contents - so a call is a
/// dispatch and nothing else.
final class CoreMLEngine: Engine {
    let decodeLanes: Int
    let encodeBatch = 1
    /// Core ML returns raw logits: the host's argmax over a shared page costs
    /// nothing, and reducing in the graph would only add operations.
    let reducesInGraph = false

    private let mel: MLModel
    private let encoder: MLModel
    private let decodeStep: MLModel

    private let melProvider: MLDictionaryFeatureProvider
    private let encoderProvider: MLDictionaryFeatureProvider
    private let stepProvider: MLDictionaryFeatureProvider
    private let melOptions = MLPredictionOptions()
    private let encoderOptions = MLPredictionOptions()
    private let stepOptions = MLPredictionOptions()

    /// Lanes the decode step declares, needed before the buffers exist.
    static func declaredLanes(directory: URL, computeUnits: MLComputeUnits) throws -> Int {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let model = try MLModel(
            contentsOf: directory.appendingPathComponent(VozModel.decodeStep),
            configuration: configuration)
        guard let embed = model.modelDescription.inputDescriptionsByName["embed"],
              let constraint = embed.multiArrayConstraint, constraint.shape[0].intValue > 0 else {
            throw VozError.invalidModel("decode step is missing its embed input")
        }
        return constraint.shape[0].intValue
    }

    init(directory: URL, computeUnits: MLComputeUnits, buffers: PipelineBuffers) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        func load(_ name: String) throws -> MLModel {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VozError.invalidModel("missing \(name) in \(directory.path)")
            }
            return try MLModel(contentsOf: url, configuration: configuration)
        }
        mel = try load(VozModel.mel)
        encoder = try load(VozModel.encoder)
        decodeStep = try load(VozModel.decodeStep)

        guard let embed = decodeStep.modelDescription.inputDescriptionsByName["embed"],
              let constraint = embed.multiArrayConstraint else {
            throw VozError.invalidModel("decode step is missing its embed input")
        }
        decodeLanes = constraint.shape[0].intValue
        guard decodeLanes > 0 else {
            throw VozError.invalidModel("decode step declares no lanes")
        }

        melProvider = try MLDictionaryFeatureProvider(dictionary: [
            "audio_rows": MLFeatureValue(multiArray: buffers.rows.array),
            "mel_mask": MLFeatureValue(multiArray: buffers.melMask.array)])
        encoderProvider = try MLDictionaryFeatureProvider(dictionary: [
            "mel": MLFeatureValue(multiArray: buffers.melOut.array),
            "key_bias": MLFeatureValue(multiArray: buffers.keyBias.array),
            "pad_mask": MLFeatureValue(multiArray: buffers.padMask.array)])
        stepProvider = try MLDictionaryFeatureProvider(dictionary: [
            "embed": MLFeatureValue(multiArray: buffers.embed.array),
            "h_in": MLFeatureValue(multiArray: buffers.hIn.array),
            "c_in": MLFeatureValue(multiArray: buffers.cIn.array),
            "enc_step": MLFeatureValue(multiArray: buffers.encStep.array)])
        // Write predictions straight into our own storage instead of letting
        // Core ML allocate a result per call.
        melOptions.outputBackings = ["mel": buffers.melOut.array]
        encoderOptions.outputBackings = ["enc_proj": buffers.encOut.array]
        stepOptions.outputBackings = [
            "logits": buffers.logitsOut.array, "h_out": buffers.hOut.array,
            "c_out": buffers.cOut.array]
    }

    // The buffers are already bound into the providers and backings, so these
    // take their arguments only to satisfy the protocol.
    //
    // `predict` is a synchronous helper on purpose. Core ML offers an async
    // `prediction(from:options:)` as well, and in an async context Swift picks
    // it - which would hand every dispatch to the concurrency runtime for no
    // reason. The engine is async because the *wasm* host is; on this path
    // nothing suspends.

    private func predict(_ model: MLModel, _ provider: MLDictionaryFeatureProvider,
                         _ options: MLPredictionOptions) throws {
        _ = try model.prediction(from: provider, options: options)
    }

    func runMel(rows: Buffer, melMask: Buffer, mel melBuffer: Buffer,
                isolation: isolated (any Actor)?) async throws {
        try predict(mel, melProvider, melOptions)
    }

    func runEncoder(mel: Buffer, keyBias: Buffer, padMask: Buffer, encOut: Buffer,
                    isolation: isolated (any Actor)?) async throws {
        try predict(encoder, encoderProvider, encoderOptions)
    }

    func runDecodeStep(embed: Buffer, hIn: Buffer, cIn: Buffer, encStep: Buffer,
                       logits: Buffer, tok: inout [Int32], dur: inout [Int32],
                       hOut: Buffer, cOut: Buffer,
                       isolation: isolated (any Actor)?) async throws {
        try predict(decodeStep, stepProvider, stepOptions)
    }
}
#endif
