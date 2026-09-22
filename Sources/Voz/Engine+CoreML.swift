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
final class CoreMLEngine: Engine, @unchecked Sendable {
    let decodeLanes: Int

    /// The decode step leaves the Neural Engine only where `decodeUnits` puts
    /// it on the CPU, which is M-series silicon.
    var decodeRunsBesideEncoder: Bool { Self.decodeOnCPU }

    /// The models are `nonisolated(unsafe)` for the same reason `Slot` is
    /// unchecked: Core ML's types carry no concurrency annotations, and an
    /// `MLModel` is documented to take concurrent predictions - which is the
    /// behaviour `encodeDepth` above exists to use.
    private nonisolated(unsafe) let mel: MLModel
    private nonisolated(unsafe) let encoder: MLModel
    private nonisolated(unsafe) let decodeStep: MLModel

    /// One bound set of providers and backings per slot, built at load. A
    /// dispatch is then a dispatch: the inputs never change identity, only
    /// their contents.
    /// `@unchecked Sendable` because a slot is owned by one encode at a time -
    /// the pipeline hands out each slot index to a single task in flight - and
    /// Core ML's own types carry no concurrency annotations.
    private struct Slot: @unchecked Sendable {
        let mel: MLDictionaryFeatureProvider
        let encoder: MLDictionaryFeatureProvider
        let melOptions: MLPredictionOptions
        let encoderOptions: MLPredictionOptions
    }
    private let slots: [Slot]
    private let stepProvider: MLDictionaryFeatureProvider
    private let stepOptions = MLPredictionOptions()

    /// Where the time goes, when `VOZ_COREAI_PROFILE` asks.
    ///
    /// Shared with `CoreAIEngine` and read by the same flag, because the point
    /// of the number is the comparison: a mel/encoder/decode split from one
    /// runtime is only worth having beside the same split from the other.
    #if canImport(CoreAI)
    @available(macOS 27.0, iOS 27.0, *)
    private var profile: CoreAIEngine.Profile { Self.sharedProfile }
    @available(macOS 27.0, iOS 27.0, *)
    private static let sharedProfile = CoreAIEngine.Profile()
    private static let profiling =
        ProcessInfo.processInfo.environment["VOZ_COREAI_PROFILE"] != nil
    deinit {
        if Self.profiling, #available(macOS 27.0, iOS 27.0, *) { Self.sharedProfile.report() }
    }
    #endif

    /// Four in flight.
    ///
    /// Core ML spreads concurrent requests over the hardware, so this is what
    /// reaches the second Neural Engine of an Ultra part: measured on this
    /// encoder, 34.8 ms a window one at a time, 16.8 with two in flight, 13.2
    /// with four, flat after that. On single-engine chips it is free rather
    /// than useful - an M5 goes 25.0 to 24.7 ms, an M1 39.2 to 38.8, an iPhone
    /// 16 Pro 30.9 to 30.8 - because one window already fills the engine.
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
    /// 242 to 251. A phone measures the other way (309 against 280) and keeps
    /// the engine.
    ///
    /// Asked for in both places the decode step is loaded, so the two share one
    /// specialization rather than compiling the model twice.
    static func decodeUnits(_ asked: MLComputeUnits) -> MLComputeUnits {
        decodeOnCPU ? .cpuOnly : asked
    }

    /// `VOZ_COREML_DECODE_CPU` pins the decode step to the CPU (1) or not (0),
    /// for measuring the choice on a part it was not made for.
    static let decodeOnCPU: Bool =
        ProcessInfo.processInfo.environment["VOZ_COREML_DECODE_CPU"].map { $0 != "0" }
            ?? Silicon.isMSeries

    /// Lanes the decode step declares, needed before the buffers exist.
    static func declaredLanes(directory: URL, computeUnits: MLComputeUnits) throws -> Int {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = decodeUnits(computeUnits)
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
        decodeStep = try load(VozModel.decodeStep, options(Self.decodeUnits(computeUnits)))

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
            // Write predictions straight into our own storage instead of
            // letting Core ML allocate a result per call.
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
    }

    // The buffers are already bound into the providers and backings, so these
    // take their arguments only to satisfy the protocol.
    //
    // `predict` is a synchronous helper on purpose, and this is the load-bearing
    // part. Core ML offers an async `prediction(from:options:)` as well, and in
    // an async context Swift picks it - which would hand every dispatch to the
    // concurrency runtime, for a call that returns without ever suspending. The
    // protocol is async so a runtime that must suspend can; this one does not.

    private func predict(_ model: MLModel, _ provider: MLDictionaryFeatureProvider,
                         _ options: MLPredictionOptions) throws {
        _ = try model.prediction(from: provider, options: options)
    }

    func encode(slot index: Int, buffers: PipelineBuffers,
                isolation: isolated (any Actor)?) async throws {
        let slot = slots[index]
        #if canImport(CoreAI)
        var start = Self.profiling ? DispatchTime.now().uptimeNanoseconds : 0
        #endif
        // `async` on the model itself, unlike the decode step below: this is
        // the call that is meant to overlap, and Core ML's own async prediction
        // is what puts several of them in its queue at once.
        _ = try await mel.prediction(from: slot.mel, options: slot.melOptions)
        #if canImport(CoreAI)
        if Self.profiling, #available(macOS 27.0, iOS 27.0, *) {
            let now = DispatchTime.now().uptimeNanoseconds
            profile.add(mel: Int(now - start))
            start = now
        }
        #endif
        _ = try await encoder.prediction(from: slot.encoder, options: slot.encoderOptions)
        #if canImport(CoreAI)
        if Self.profiling, #available(macOS 27.0, iOS 27.0, *) {
            profile.add(encode: Int(DispatchTime.now().uptimeNanoseconds - start))
        }
        #endif
    }

    func runDecodeStep(embed: Buffer, hIn: Buffer, cIn: Buffer, encStep: Buffer,
                       logits: Buffer, hOut: Buffer, cOut: Buffer, activeLanes: [Int],
                       isolation: isolated (any Actor)?) async throws {
        #if canImport(CoreAI)
        let start = Self.profiling ? DispatchTime.now().uptimeNanoseconds : 0
        try predict(decodeStep, stepProvider, stepOptions)
        if Self.profiling, #available(macOS 27.0, iOS 27.0, *) {
            profile.add(decode: Int(DispatchTime.now().uptimeNanoseconds - start))
        }
        #else
        try predict(decodeStep, stepProvider, stepOptions)
        #endif
    }
}
#endif
