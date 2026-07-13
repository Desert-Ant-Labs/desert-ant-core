#if canImport(CoreML)
import CoreML
import Foundation

/// Core ML inference backend (Apple platforms): a compiled `.mlmodelc` behind
/// the shared ``InferenceSession`` API.
///
/// Inputs must be `int32` or `float32` (Core ML has no int64 tensors; export
/// models accordingly). `float32`/`int32` outputs are copied out directly;
/// other output types (e.g. float16) are converted to `float32` elementwise,
/// which is slow for large outputs, so exporters should emit `float32`.
public final class CoreMLSession: InferenceSession, @unchecked Sendable {
    private let model: MLModel

    /// Load a compiled model. The default configuration uses every compute
    /// unit on device (CPU-only in the simulator); pass your own to override,
    /// e.g. `.cpuAndNeuralEngine` for large models.
    public init(modelPath: String, configuration: MLModelConfiguration = CoreMLSession.defaultConfiguration()) throws {
        model = try MLModel(contentsOf: URL(fileURLWithPath: modelPath), configuration: configuration)
    }

    public static func defaultConfiguration() -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
        #else
        configuration.computeUnits = .all
        #endif
        return configuration
    }

    public func run(inputs: [String: Tensor], outputs: [String]) throws -> [Tensor] {
        var features: [String: Any] = [:]
        for (name, tensor) in inputs { features[name] = try multiArray(tensor) }
        let provider = try MLDictionaryFeatureProvider(dictionary: features)
        let prediction = try model.prediction(from: provider)
        return try outputs.map { name in
            guard let array = prediction.featureValue(for: name)?.multiArrayValue else {
                throw InferenceError.runFailed("the model returned no '\(name)'")
            }
            return try tensor(array)
        }
    }

    private func multiArray(_ tensor: Tensor) throws -> MLMultiArray {
        let dataType: MLMultiArrayDataType
        switch tensor.element {
        case .int32: dataType = .int32
        case .float32: dataType = .float32
        case .int64:
            throw InferenceError.invalidTensor("Core ML takes int32, not int64; export the model accordingly")
        }
        let array = try MLMultiArray(shape: tensor.shape.map { NSNumber(value: $0) }, dataType: dataType)
        array.withUnsafeMutableBytes { destination, _ in
            tensor.bytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        return array
    }

    private func tensor(_ array: MLMultiArray) throws -> Tensor {
        let shape = array.shape.map(\.intValue)
        let count = shape.reduce(1, *)
        switch array.dataType {
        case .float32:
            return try Tensor(element: .float32, shape: shape, bytes: copyBytes(array, count * 4))
        case .int32:
            return try Tensor(element: .int32, shape: shape, bytes: copyBytes(array, count * 4))
        default:
            // float16/float64 outputs: convert through the typed subscript.
            var values = [Float](repeating: 0, count: count)
            for index in 0..<count { values[index] = array[index].floatValue }
            return Tensor(float32: values, shape: shape)
        }
    }

    private func copyBytes(_ array: MLMultiArray, _ byteCount: Int) -> [UInt8] {
        array.withUnsafeBytes { source in
            precondition(source.count >= byteCount, "MLMultiArray smaller than its shape")
            return Array(source.prefix(byteCount))
        }
    }
}
#endif
