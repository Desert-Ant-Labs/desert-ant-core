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
        if array.dataType == .float16, contiguous {
            let src = array.dataPointer.assumingMemoryBound(to: UInt16.self)
            var s = vImage_Buffer(data: .init(mutating: src), height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
            out.withUnsafeMutableBufferPointer { dp in
                var d = vImage_Buffer(data: dp.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                vImageConvert_Planar16FtoPlanarF(&s, &d, 0)
            }
        } else if array.dataType == .float32, contiguous {
            out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: array.dataPointer.assumingMemoryBound(to: Float.self), count: count) }
        } else {
            // Strided (ANE-padded inner dims) or float64: correct, slower path.
            for i in 0..<count { out[i] = array[i].floatValue }
        }
        return Tensor(float32: out, shape: shape)
    }

    private func isContiguous(_ array: MLMultiArray) -> Bool {
        let shape = array.shape.map(\.intValue), strides = array.strides.map(\.intValue)
        var expected = 1
        for i in (0..<shape.count).reversed() {
            if strides[i] != expected { return false }
            expected *= shape[i]
        }
        return true
    }
}

extension ComputeUnits {
    var mlComputeUnits: MLComputeUnits {
        switch self {
        case .all: return .all
        case .cpuAndNeuralEngine: return .cpuAndNeuralEngine
        case .cpuOnly: return .cpuOnly
        }
    }
}

#endif
