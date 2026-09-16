#if canImport(CoreML)
import CoreML
import Accelerate
import Foundation
import PlatformSupport

/// Core ML inference backend (Apple platforms): a compiled `.mlmodelc` behind
/// the shared ``InferenceSession`` API.
///
/// Feeds the model's native I/O precision: when an input/output is `float16`
/// (as fp16-exported graphs declare), it converts against a `Tensor`'s
/// `float32` bytes with vImage rather than per-element `NSNumber` subscripting,
/// which is orders of magnitude faster on large tensors (and lets Core ML run
/// the pure-fp16 graph instead of inserting casts). The MLMultiArrays and the
/// feature provider are built once and reused across `run` calls of the same
/// shape (e.g. a fixed-window model over many chunks). `int32`/`float32` I/O is
/// copied directly; `int64` inputs are rejected (Core ML has no int64 tensors).
final class CoreMLSession: InferenceSession, @unchecked Sendable {
    private let model: MLModel
    /// What the model was actually loaded with, after the environment and the
    /// simulator have had their say. `run(batch:)` needs to know.
    private let units: MLComputeUnits
    private let lock = NSLock()
    private var inArrays: [String: MLMultiArray] = [:]
    private var provider: MLDictionaryFeatureProvider?

    /// Load a compiled model. `computeUnits` is what the model SDK asks for
    /// (Core ML's `MLComputeUnits`); the environment and the simulator can
    /// override it - see ``configuration(for:)``.
    /// - Parameter functionName: which function of a multifunction model to run. One
    ///   `.mlmodelc` can carry several graphs - a selector and a scorer sharing an encoder,
    ///   say - and shipping them as one asset stores the shared weights once rather than
    ///   twice. `nil` uses the model's default function, which is every single-function
    ///   model.
    init(modelPath: String, computeUnits: ComputeUnits = .all,
         functionName: String? = nil) throws {
        let configuration = CoreMLSession.configuration(for: computeUnits)
        if let functionName {
            // watchOS 11.0 belongs here even though this package declares no watchOS platform.
            // `MLModelConfiguration.functionName` is annotated watchOS 11.0+ in the Core ML
            // header, and a platform left out of an `#available` list falls to `*` — which
            // matches every watchOS version, so the guard PASSES and the line below then fails
            // to COMPILE against the watchOS SDK. An omission here is a build error rather
            // than a runtime fallback, and `ModelPlatform.current` does route watchOS to
            // `.apple`.
            guard #available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, watchOS 11.0, *)
            else {
                throw InferenceError.sessionUnavailable(
                    "multifunction models need iOS 18 / macOS 15; '\(functionName)' is unreachable here")
            }
            configuration.functionName = functionName
        }
        units = configuration.computeUnits
        model = try MLModel(contentsOf: URL(fileURLWithPath: modelPath),
                            configuration: configuration)
    }

    /// The configuration to load with, in precedence order:
    ///
    /// 1. `DAL_COREML_COMPUTE_UNITS` (`cpu`, `cpuAndGPU`, `cpuAndNeuralEngine`,
    ///    `all`) - how a CI job pins itself to a configuration that is
    ///    reproducible there. A virtualized macOS host (CI runners) has no
    ///    Neural Engine, and `.all` can silently yield useless outputs rather
    ///    than failing.
    /// 2. The simulator, which has no Neural Engine: CPU only.
    /// 3. What the caller asked for (the SDK's own measured best choice).
    static func configuration(for requested: ComputeUnits = .all) -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        switch environmentVariable("DAL_COREML_COMPUTE_UNITS") {
        case "cpu", "cpuOnly": configuration.computeUnits = .cpuOnly
        case "cpuAndGPU": configuration.computeUnits = .cpuAndGPU
        case "cpuAndNeuralEngine": configuration.computeUnits = .cpuAndNeuralEngine
        case "all": configuration.computeUnits = .all
        default:
            #if targetEnvironment(simulator)
            configuration.computeUnits = .cpuOnly
            #else
            configuration.computeUnits = requested.mlComputeUnits
            #endif
        }
        return configuration
    }

    /// Read off the declared constraint. On a multifunction package `modelDescription` reflects
    /// the function this session was configured with, so `select` and `score` report their own
    /// widths from two sessions over the same file.
    func inputWidth(_ name: String) -> Int? {
        guard let shape = model.modelDescription
            .inputDescriptionsByName[name]?.multiArrayConstraint?.shape,
              let last = shape.last?.intValue, last > 0 else { return nil }
        return last
    }

    /// One submission carrying every input, where that is faster than one call
    /// each - see the protocol's `run(batch:outputs:)`.
    ///
    /// Not gated by platform. It is worth nothing on the phones measured - an
    /// iPhone 16 Pro runs Voz's encoder at 31 ms a window alone and 41 in a
    /// batch of four, because one engine and 60 GB/s are already saturated by a
    /// single window - but the caller's batch size is chosen by measurement, so
    /// such a device settles back on one and ends where it started. An iPad with
    /// a desktop-class chip, or a phone with a second engine, would find the
    /// same way a Mac does rather than waiting for this line to be revisited.
    ///
    /// `.all` is excluded because Core ML gets it wrong, not because it is slow:
    /// a batch that the runtime splits across devices came back with items
    /// duplicated - 17 of 24 windows in a Uhm run were copies of another
    /// window's output, and its filler count changed. Pinned to one device the
    /// same batch is identical to predicting each item alone, on every model
    /// here.
    func run(batch: [[String: Tensor]], outputs: [String]) async throws -> [[Tensor]] {
        // `async` to match the requirement exactly. A synchronous method is a
        // legal witness only when nothing else matches better, and here the
        // protocol carries a default: the compiler took the default, silently,
        // and every batch went back through the loop this exists to replace.
        try predict(batch: batch, outputs: outputs)
    }

    private func predict(batch: [[String: Tensor]], outputs: [String]) throws -> [[Tensor]] {
        // `.all` is excluded because Core ML gets it wrong, not because it is
        // slow: a batch that the runtime splits across devices came back with
        // items duplicated - 17 of 24 windows in a Uhm run were copies of
        // another window's output, and the transcript-equivalent (its filler
        // count) changed. Pinned to one device the same batch is identical to
        // predicting each item alone, on every window. So a caller who wants
        // batching pins; everyone else gets the loop, unchanged.
        guard units != .all, batch.count > 1 else {
            return try batch.map { try run(inputs: $0, outputs: outputs, deviceId: nil) }
        }
        lock.lock(); defer { lock.unlock() }
        let desc = model.modelDescription.inputDescriptionsByName
        // A provider per item, built fresh: the cached single-input arrays this
        // session reuses belong to `run(inputs:)`, and a batch needs its own
        // storage for every item at once anyway.
        let providers = try batch.map { inputs -> MLDictionaryFeatureProvider in
            var features: [String: Any] = [:]
            for (name, tensor) in inputs {
                let type = try dataType(for: tensor,
                                        declared: desc[name]?.multiArrayConstraint?.dataType)
                let array = try MLMultiArray(shape: tensor.shape.map { NSNumber(value: $0) },
                                             dataType: type)
                write(tensor, into: array)
                features[name] = array
            }
            return try MLDictionaryFeatureProvider(dictionary: features)
        }
        if environmentVariable("DAL_TRACE_BATCH") != nil {
            FileHandle.standardError.write(Data("BATCH n=\(batch.count)\n".utf8))
        }
        let predictions = try model.predictions(from: MLArrayBatchProvider(array: providers),
                                                options: MLPredictionOptions())
        return try (0..<predictions.count).map { index in
            let features = predictions.features(at: index)
            return try outputs.map { name in
                guard let array = features.featureValue(for: name)?.multiArrayValue else {
                    throw InferenceError.runFailed("the model returned no '\(name)'")
                }
                return readTensor(array)
            }
        }
    }

    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) throws -> [Tensor] {
        lock.lock(); defer { lock.unlock() }
        let desc = model.modelDescription.inputDescriptionsByName

        // Build (once) and reuse the input arrays + provider; rebuild only when
        // the set of inputs or a shape changes.
        if provider == nil || !cacheMatches(inputs) {
            inArrays.removeAll(keepingCapacity: true)
            var features: [String: Any] = [:]
            for (name, tensor) in inputs {
                let dt = try dataType(for: tensor, declared: desc[name]?.multiArrayConstraint?.dataType)
                let array = try MLMultiArray(shape: tensor.shape.map { NSNumber(value: $0) }, dataType: dt)
                inArrays[name] = array
                features[name] = array
            }
            provider = try MLDictionaryFeatureProvider(dictionary: features)
        }
        for (name, tensor) in inputs { write(tensor, into: inArrays[name]!) }

        let prediction = try model.prediction(from: provider!)
        return try outputs.map { name in
            guard let array = prediction.featureValue(for: name)?.multiArrayValue else {
                throw InferenceError.runFailed("the model returned no '\(name)'")
            }
            return readTensor(array)
        }
    }

    private func cacheMatches(_ inputs: [String: Tensor]) -> Bool {
        guard inArrays.count == inputs.count else { return false }
        for (name, tensor) in inputs {
            guard let a = inArrays[name], a.shape.map(\.intValue) == tensor.shape else { return false }
        }
        return true
    }

    private func dataType(for tensor: Tensor, declared: MLMultiArrayDataType?) throws -> MLMultiArrayDataType {
        switch tensor.element {
        case .int64:
            throw InferenceError.invalidTensor("Core ML takes int32, not int64; export the model accordingly")
        case .int32:
            return .int32
        case .float32:
            // Match the model's declared precision so an fp16 graph gets fp16.
            return declared == .float16 ? .float16 : .float32
        }
    }

    private func write(_ tensor: Tensor, into array: MLMultiArray) {
        let count = tensor.count
        tensor.bytes.withUnsafeBytes { raw in
            if array.dataType == .float16 {
                let src = raw.bindMemory(to: Float.self)
                var s = vImage_Buffer(data: .init(mutating: src.baseAddress!), height: 1,
                                      width: vImagePixelCount(count), rowBytes: count * 4)
                var d = vImage_Buffer(data: array.dataPointer, height: 1,
                                      width: vImagePixelCount(count), rowBytes: count * 2)
                vImageConvert_PlanarFtoPlanar16F(&s, &d, 0)
            } else {
                // Copy exactly the source bytes. Only .int32 and .float32 reach
                // here (see dataType(for:)) and both are 4 bytes per element, so
                // this is the same size the destination was allocated for.
                //
                // Deliberately not derived from array.dataType: switching on
                // MLMultiArrayDataType means guessing a width for whatever case
                // a future SDK adds, and guessing too wide overruns the array's
                // buffer. Core ML added .int8 (1 byte) exactly that way.
                array.dataPointer.copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
        }
    }

    private func readTensor(_ array: MLMultiArray) -> Tensor {
        let shape = array.shape.map(\.intValue)
        let count = shape.reduce(1, *)
        let contiguous = isContiguous(array)
        if array.dataType == .int32, contiguous {
            let bytes = array.dataPointer.withMemoryRebound(to: UInt8.self, capacity: count * 4) {
                Array(UnsafeBufferPointer(start: $0, count: count * 4))
            }
            return (try? Tensor(element: .int32, shape: shape, bytes: bytes)) ?? Tensor(float32: [], shape: shape)
        }
        var out = [Float](repeating: 0, count: count)
        if array.dataType == .float16, let rows = rowContiguousLayout(array) {
            // ANE commonly pads the innermost row (for example 200 values to
            // a stride of 224). Convert each logical row from the raw buffer;
            // NSNumber subscripting here costs several times the prediction.
            let src = array.dataPointer.assumingMemoryBound(to: UInt16.self)
            out.withUnsafeMutableBufferPointer { dp in
                for row in 0..<rows.count {
                    var s = vImage_Buffer(
                        data: .init(mutating: src + row * rows.stride), height: 1,
                        width: vImagePixelCount(rows.length), rowBytes: rows.length * 2)
                    var d = vImage_Buffer(
                        data: dp.baseAddress! + row * rows.length, height: 1,
                        width: vImagePixelCount(rows.length), rowBytes: rows.length * 4)
                    vImageConvert_Planar16FtoPlanarF(&s, &d, 0)
                }
            }
        } else if array.dataType == .float32, let rows = rowContiguousLayout(array) {
            let src = array.dataPointer.assumingMemoryBound(to: Float.self)
            out.withUnsafeMutableBufferPointer { dp in
                for row in 0..<rows.count {
                    (dp.baseAddress! + row * rows.length)
                        .update(from: src + row * rows.stride, count: rows.length)
                }
            }
        } else {
            // Genuinely arbitrary strides or float64: correct, slower path.
            for i in 0..<count { out[i] = array[i].floatValue }
        }
        return Tensor(float32: out, shape: shape)
    }

    private func isContiguous(_ array: MLMultiArray) -> Bool {
        guard let rows = rowContiguousLayout(array) else { return false }
        return rows.stride == rows.length
    }

    /// A dense sequence of fixed-stride innermost rows. Core ML may pad between
    /// rows, but every higher dimension must still be a regular product of the
    /// dimension below it.
    private func rowContiguousLayout(_ array: MLMultiArray)
        -> (count: Int, length: Int, stride: Int)? {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count >= 2, strides.count == shape.count,
              strides.last == 1 else { return nil }
        let rowStride = strides[shape.count - 2]
        guard rowStride >= shape.last! else { return nil }
        if shape.count > 2 {
            for i in 0..<(shape.count - 2) where strides[i] != shape[i + 1] * strides[i + 1] {
                return nil
            }
        }
        return (shape.dropLast().reduce(1, *), shape.last!, rowStride)
    }
}

extension ComputeUnits {
    /// The Core ML spelling. Public because callers that hold an `MLModel`
    /// directly, rather than a session, still choose placement through
    /// `Placement` and need to apply the answer.
    public var mlComputeUnits: MLComputeUnits {
        switch self {
        case .all: return .all
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        case .cpuAndGPU: return .cpuAndGPU
        case .cpuOnly: return .cpuOnly
        }
    }
}

#endif
