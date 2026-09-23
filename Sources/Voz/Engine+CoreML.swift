#if canImport(CoreML)
import CoreML
import Foundation

/// The Core ML engine: three compiled programs, driven with preallocated
/// buffers and `outputBackings` so a prediction allocates nothing.
///
/// The feature providers and options are built once at init because the
/// inputs never change identity, only their contents, so a call is a dispatch
/// and nothing else.
final class CoreMLEngine: Engine, @unchecked Sendable {
    let decodeLanes: Int
    let encodeBatch = 1
    /// Core ML returns raw logits: the host's argmax over a shared page costs
    /// nothing, and reducing in the graph would only add operations.
    let reducesInGraph = false

    let decodeRunsBesideEncoder = true

    /// The models are `nonisolated(unsafe)` for the same reason `Slot` is
    /// unchecked: Core ML's types carry no concurrency annotations, and an
    /// `MLModel` is documented to take concurrent predictions, which
    /// `encodeDepth` exists to use.
    private nonisolated(unsafe) let mel: MLModel
    private nonisolated(unsafe) let encoder: MLModel
    private nonisolated(unsafe) let decodeStep: MLModel

    /// One bound set of providers and backings per slot, built at load.
    /// `@unchecked Sendable` because the pipeline hands each slot index to a
    /// single task in flight, and Core ML's types carry no concurrency
    /// annotations.
    private struct Slot: @unchecked Sendable {
        let mel: MLDictionaryFeatureProvider
        let encoder: MLDictionaryFeatureProvider
        let melOptions: MLPredictionOptions
        let encoderOptions: MLPredictionOptions
    }
    private let slots: [Slot]
    private let stepProvider: MLDictionaryFeatureProvider
    private let stepOptions = MLPredictionOptions()

    /// The decode step at fewer lanes (`decoder_1` ... `decoder_8`), smallest
    /// first, where the decoder is a multifunction model that carries them.
    private struct Narrow {
        let lanes: Int
        let model: MLModel
        let provider: MLDictionaryFeatureProvider
        let options: MLPredictionOptions
        let embed, hIn, cIn, encStep, logits, hOut, cOut: Buffer
    }
    private let narrow: [Narrow]

    /// Four in flight.
    ///
    /// Core ML spreads concurrent requests over the hardware, so this is what
    /// reaches the second Neural Engine of an Ultra part: measured on this
    /// encoder, 34.8 ms a window one at a time, 16.8 with two in flight, 13.2
    /// with four, flat after that. On single-engine chips it is free rather
    /// than useful (an M5 goes 25.0 to 24.7 ms, an M1 39.2 to 38.8, an iPhone
    /// 16 Pro 30.9 to 30.8) because one window already fills the engine.
    var encodeDepth: Int { Self.encodeDepthForLoad }

    /// Read before the engine exists, because the buffers it binds are sized
    /// by it. `VOZ_ENCODE_DEPTH` pins it.
    static let encodeDepthForLoad =
        Int(ProcessInfo.processInfo.environment["VOZ_ENCODE_DEPTH"] ?? "") ?? 4

    /// Where the decode step runs.
    ///
    /// It is small and dispatch-bound, and it runs beside the encoder rather
    /// than after it, so on the Neural Engine it queues behind engine work
    /// while a performance core sits idle. Measured over ten minutes of speech:
    /// an M3 Ultra goes from 181 to 310 RTFx, an M5 from 405 to 443, an M1 from
    /// 242 to 251. A phone wins too with the narrow steps, which the pipeline
    /// then overlaps with the encoder.
    ///
    /// Asked for in every place the decode step is loaded, so they share one
    /// specialization rather than compiling the model twice.
    static let decodeUnits = MLComputeUnits.cpuOnly

    /// Lanes the decode step declares, needed before the buffers exist.
    static func declaredLanes(directory: URL) throws -> Int {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = decodeUnits
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
        decodeStep = try load(VozModel.decodeStep, options(Self.decodeUnits))

        guard let embed = decodeStep.modelDescription.inputDescriptionsByName["embed"],
              let constraint = embed.multiArrayConstraint else {
            throw VozError.invalidModel("decode step is missing its embed input")
        }
        decodeLanes = constraint.shape[0].intValue
        guard decodeLanes > 0 else {
            throw VozError.invalidModel("decode step declares no lanes")
        }

        slots = try buffers.slots.map { slot in
            let melOptions = MLPredictionOptions()
            let encoderOptions = MLPredictionOptions()
            melOptions.outputBackings = ["mel": slot.melOut.array]
            encoderOptions.outputBackings = ["enc_proj": slot.encOut.array]
            return Slot(
                mel: try MLDictionaryFeatureProvider(dictionary: [
                    "audio_rows": MLFeatureValue(multiArray: slot.rows.array),
                    "mel_mask": MLFeatureValue(multiArray: slot.melMask.array)]),
                encoder: try MLDictionaryFeatureProvider(dictionary: [
                    "mel": MLFeatureValue(multiArray: slot.melOut.array),
                    "key_bias": MLFeatureValue(multiArray: slot.keyBias.array),
                    "pad_mask": MLFeatureValue(multiArray: buffers.padMask.array)]),
                melOptions: melOptions, encoderOptions: encoderOptions)
        }
        stepProvider = try MLDictionaryFeatureProvider(dictionary: [
            "embed": MLFeatureValue(multiArray: buffers.embed.array),
            "h_in": MLFeatureValue(multiArray: buffers.hIn.array),
            "c_in": MLFeatureValue(multiArray: buffers.cIn.array),
            "enc_step": MLFeatureValue(multiArray: buffers.encStep.array)])
        stepOptions.outputBackings = [
            "logits": buffers.logitsOut.array, "h_out": buffers.hOut.array,
            "c_out": buffers.cOut.array]

        var narrow: [Narrow] = []
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, *) {
            let full = decodeLanes
            for lanes in [1, 2, 4, 8] where lanes < full {
                let configuration = options(Self.decodeUnits)
                configuration.functionName = "decoder_\(lanes)"
                guard let model = try? MLModel(
                    contentsOf: directory.appendingPathComponent(VozModel.decodeStep),
                    configuration: configuration) else { continue }
                func make(_ like: Buffer) throws -> Buffer {
                    try Buffer([lanes] + like.shape.dropFirst())
                }
                let embed = try make(buffers.embed), hIn = try make(buffers.hIn)
                let cIn = try make(buffers.cIn), encStep = try make(buffers.encStep)
                let logits = try make(buffers.logitsOut), hOut = try make(buffers.hOut)
                let cOut = try make(buffers.cOut)
                let options = MLPredictionOptions()
                options.outputBackings = ["logits": logits.array, "h_out": hOut.array,
                                          "c_out": cOut.array]
                narrow.append(Narrow(
                    lanes: lanes, model: model,
                    provider: try MLDictionaryFeatureProvider(dictionary: [
                        "embed": MLFeatureValue(multiArray: embed.array),
                        "h_in": MLFeatureValue(multiArray: hIn.array),
                        "c_in": MLFeatureValue(multiArray: cIn.array),
                        "enc_step": MLFeatureValue(multiArray: encStep.array)]),
                    options: options, embed: embed, hIn: hIn, cIn: cIn, encStep: encStep,
                    logits: logits, hOut: hOut, cOut: cOut))
            }
        }
        self.narrow = narrow
    }

    /// Runs the smallest narrow step that holds `activeLanes`, if there is one.
    private func runNarrow(embed: Buffer, hIn: Buffer, cIn: Buffer, encStep: Buffer,
                           logits: Buffer, hOut: Buffer, cOut: Buffer,
                           activeLanes: [Int]) throws -> Bool {
        guard let small = narrow.first(where: { $0.lanes >= activeLanes.count }) else {
            return false
        }
        func gather(_ from: Buffer, _ into: Buffer) {
            let per = from.count / decodeLanes
            for (i, lane) in activeLanes.enumerated() {
                (into.ptr + i * per).update(from: from.ptr + lane * per, count: per)
            }
        }
        func scatter(_ from: Buffer, _ into: Buffer) {
            let per = into.count / decodeLanes
            for (i, lane) in activeLanes.enumerated() {
                (into.ptr + lane * per).update(from: from.ptr + i * per, count: per)
            }
        }
        gather(embed, small.embed); gather(hIn, small.hIn)
        gather(cIn, small.cIn); gather(encStep, small.encStep)
        try predict(small.model, small.provider, small.options)
        scatter(small.logits, logits); scatter(small.hOut, hOut); scatter(small.cOut, cOut)
        return true
    }

    // The buffers are already bound into the providers and backings, so these
    // take their arguments only to satisfy the protocol. `lanes` is one of
    // them: this graph is a fixed shape, so a short batch cannot exist here.
    //
    // `predict` is a synchronous helper on purpose: in an async context Swift
    // would pick Core ML's async `prediction(from:options:)`, handing every
    // decode dispatch to the concurrency runtime for no reason. `encode` is the
    // call that wants the async form.

    private func predict(_ model: MLModel, _ provider: MLDictionaryFeatureProvider,
                         _ options: MLPredictionOptions) throws {
        _ = try model.prediction(from: provider, options: options)
    }

    func encode(slot index: Int, lanes: Int, buffers: PipelineBuffers,
                isolation: isolated (any Actor)?) async throws {
        let slot = slots[index]
        // `async` on the model itself, unlike the decode step below: this is
        // the call that is meant to overlap, and Core ML's own async prediction
        // is what puts several of them in its queue at once.
        _ = try await mel.prediction(from: slot.mel, options: slot.melOptions)
        _ = try await encoder.prediction(from: slot.encoder, options: slot.encoderOptions)
    }

    func runDecodeStep(embed: Buffer, hIn: Buffer, cIn: Buffer, encStep: Buffer,
                       logits: Buffer, tok: inout [Int32], dur: inout [Int32],
                       hOut: Buffer, cOut: Buffer, activeLanes: [Int],
                       isolation: isolated (any Actor)?) async throws {
        if try !runNarrow(embed: embed, hIn: hIn, cIn: cIn, encStep: encStep, logits: logits,
                          hOut: hOut, cOut: cOut, activeLanes: activeLanes) {
            try predict(decodeStep, stepProvider, stepOptions)
        }
    }
}
#endif
