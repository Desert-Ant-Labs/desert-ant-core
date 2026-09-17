#if canImport(CoreML)
import CoreML
import Foundation
import Inference

/// The Core ML engine: three compiled programs, driven with preallocated
/// buffers and `outputBackings` so a prediction allocates nothing.
///
/// This is the path the shipping numbers come from, and its shape is load
/// bearing. The feature providers and options are built once at init because
/// the inputs never change identity - only their contents - so a call is a
/// dispatch and nothing else.
final class CoreMLEngine: Engine {
    let decodeLanes: Int
    /// One while the decode placement is still being settled, so the run this
    /// times is the same pipeline the other placement's run was. See
    /// ``DecodePlacement/exploring(model:)``.
    var encodeBatch: Int {
        guard batches, !placementExploring else { return 1 }
        return min(BatchSize.next(model: measurementIdentity), batchMel.count)
    }
    private let batches: Bool
    private let placementExploring: Bool
    private let measurementIdentity: String
    private let placementIdentity: String
    private let decodePlacement: String
    private let measuresPlacement: Bool
    private let batchMel: [Buffer]
    private let batchBias: [Buffer]
    private let batchProviders: [MLDictionaryFeatureProvider]
    private let channels: Int
    private let frames: Int
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

    init(directory: URL, computeUnits: MLComputeUnits, buffers: PipelineBuffers,
         overlapsDecode: Bool) throws {
        batches = computeUnits != .all
        placementIdentity = "\(directory.path)|\(VozModel.revision)|encoder=\(computeUnits.rawValue)|overlap=\(overlapsDecode)|v2"
        let placement = computeUnits == .cpuAndNeuralEngine
            ? DecodePlacement.next(model: placementIdentity)
            : (name: "caller-\(computeUnits.rawValue)", units: computeUnits)
        decodePlacement = placement.name
        measuresPlacement = computeUnits == .cpuAndNeuralEngine && Placement.explores
        placementExploring = measuresPlacement && DecodePlacement.exploring(model: placementIdentity)
        measurementIdentity = "\(placementIdentity)|decode=\(placement.name)"
        channels = buffers.encOut.shape[1]
        frames = buffers.encOut.shape[3]
        let slots = batches ? (BatchSize.candidates.max() ?? 1) : 1
        batchMel = try (0..<slots).map { _ in try Buffer(buffers.melOut.shape) }
        batchBias = try (0..<slots).map { _ in try Buffer(buffers.keyBias.shape) }
        batchProviders = try zip(batchMel, batchBias).map { mel, bias in
            try MLDictionaryFeatureProvider(dictionary: [
                "mel": MLFeatureValue(multiArray: mel.array),
                "key_bias": MLFeatureValue(multiArray: bias.array),
                "pad_mask": MLFeatureValue(multiArray: buffers.padMask.array)])
        }
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
        let decodeConfiguration = MLModelConfiguration()
        decodeConfiguration.computeUnits = placement.units
        decodeStep = try MLModel(contentsOf: directory.appendingPathComponent(VozModel.decodeStep),
                                 configuration: decodeConfiguration)

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

    func inputLane(for slot: Int) -> Int { 0 }

    func prepareWindow(slot: Int, batchSize: Int, buffers: PipelineBuffers,
                       isolation: isolated (any Actor)?) async throws {
        try predict(mel, melProvider, melOptions)
        // Size one keeps the original output-backed path, with no staging copy.
        guard batchSize > 1 else { return }
        batchMel[slot].ptr.update(from: buffers.melOut.ptr, count: buffers.melOut.count)
        batchBias[slot].ptr.update(from: buffers.keyBias.ptr, count: buffers.keyBias.count)
    }

    func encode(count: Int, buffers: PipelineBuffers,
                into destination: UnsafeMutablePointer<Element>, stride: Int,
                isolation: isolated (any Actor)?) async throws {
        try encodeSynchronously(count: count, buffers: buffers, into: destination, stride: stride)
    }

    private func encodeSynchronously(count: Int, buffers: PipelineBuffers,
                                     into destination: UnsafeMutablePointer<Element>,
                                     stride: Int) throws {
        guard batches && count > 1 else {
            try predict(encoder, encoderProvider, encoderOptions)
            destination.update(from: buffers.encOut.ptr, count: channels * frames)
            return
        }
        let results = try encoder.predictions(
            from: MLArrayBatchProvider(array: Array(batchProviders.prefix(count))),
            options: MLPredictionOptions())
        guard results.count == count else {
            throw VozError.invalidModel("encoder returned \(results.count) windows, expected \(count)")
        }
        for index in 0..<count {
            guard let array = results.features(at: index)
                .featureValue(for: "enc_proj")?.multiArrayValue else {
                throw VozError.invalidModel("the encoder returned no enc_proj")
            }
            try Self.copyProjection(array, to: destination + index * stride,
                                    channels: channels, frames: frames)
        }
    }

    /// Batch outputs cannot use outputBackings. Core ML pads 188 frames to
    /// 192 on some devices, so a flat copy silently drops transcript words.
    static func copyProjection(_ array: MLMultiArray, to destination: UnsafeMutablePointer<Element>,
                               channels: Int, frames: Int) throws {
        guard array.dataType == .float16,
              array.shape.map(\.intValue) == [1, channels, 1, frames] else {
            throw VozError.invalidModel("unexpected encoder output shape or type")
        }
        let source = array.dataPointer.assumingMemoryBound(to: Element.self)
        let channelStride = array.strides[1].intValue
        let frameStride = array.strides[3].intValue
        if frameStride == 1 && channelStride == frames {
            destination.update(from: source, count: channels * frames)
        } else {
            for channel in 0..<channels {
                let row = source + channel * channelStride
                let out = destination + channel * frames
                if frameStride == 1 {
                    out.update(from: row, count: frames)
                } else {
                    for frame in 0..<frames { out[frame] = row[frame * frameStride] }
                }
            }
        }
    }

    func recordGroup(size: Int, count: Int, seconds: Double) {
        guard batches, count >= size else { return }
        BatchSize.record(model: measurementIdentity, size: size,
                         secondsPerItem: seconds / Double(count))
    }

    /// Only while the placement is unsettled: after that the block size is
    /// moving underneath, and a sample from it would be timing that instead.
    func recordRun(windows: Int, seconds: Double) {
        guard measuresPlacement, placementExploring, windows > 0 else { return }
        DecodePlacement.record(model: placementIdentity, placement: decodePlacement,
                               secondsPerWindow: seconds / Double(windows))
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
