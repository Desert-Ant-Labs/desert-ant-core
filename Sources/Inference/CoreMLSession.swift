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
    init(modelPath: String, computeUnits: ComputeUnits = .all) throws {
        model = try MLModel(contentsOf: URL(fileURLWithPath: modelPath),
                            configuration: CoreMLSession.configuration(for: computeUnits))
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
                array.dataPointer.copyMemory(from: raw.baseAddress!, byteCount: count * array.dataType.byteWidth)
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

private extension MLMultiArrayDataType {
    var byteWidth: Int {
        switch self {
        case .float16: return 2
        case .int32, .float32: return 4
        case .double: return 8
        @unknown default: return 4
        }
    }
}
#endif
