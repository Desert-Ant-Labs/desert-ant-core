#if canImport(CoreAI)
import Accelerate
import CoreAI
import Foundation

/// Core AI inference backend (iOS 27, macOS 27): a `.aimodel` asset behind the shared ``InferenceSession`` API.
@available(macOS 27.0, iOS 27.0, tvOS 27.0, visionOS 27.0, watchOS 27.0, *)
final class CoreAISession: InferenceSession, @unchecked Sendable {
    private let function: InferenceFunction
    private let descriptor: InferenceFunctionDescriptor
    private let lock = NSLock()
    private var arrays: [String: NDArray] = [:]

    init(modelPath: String, computeUnits: ComputeUnits = .all) throws {
        let url = URL(fileURLWithPath: modelPath)
        let options = CoreAISession.options(for: computeUnits)
        // Specialization is async-only; the session factory is synchronous.
        let model = try CoreAISession.blocking { try await AIModel(contentsOf: url, options: options) }
        guard let name = model.functionNames.first,
              let function = try model.loadFunction(named: name),
              let descriptor = model.functionDescriptor(for: name) else {
            throw InferenceError.sessionUnavailable("'\(modelPath)' exposes no inference function")
        }
        self.function = function
        self.descriptor = descriptor
    }

    static func options(for units: ComputeUnits) -> SpecializationOptions {
        switch units {
        case .all: return .default
        case .cpuAndNeuralEngine: return SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
        case .cpuOnly: return .cpuOnly
        }
    }

    func inputWidth(_ name: String) -> Int? {
        guard case .ndArray(let array)? = descriptor.inputDescriptor(of: name),
              let last = array.shape.last, last > 0 else { return nil }
        return last
    }

    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor] {
        var produced = try await function.run(inputs: try bind(inputs))
        return try outputs.map { name in
            guard let value = produced.remove(name), let array = value.ndArray else {
                throw InferenceError.runFailed("the model returned no '\(name)'")
            }
            return try tensor(from: array)
        }
    }

    /// Reuses the input arrays: the runtime binds a buffer on first use, and a fresh one per call costs more than the model.
    private func bind(_ inputs: [String: Tensor]) throws -> [String: NDArray] {
        lock.lock(); defer { lock.unlock() }
        for (name, tensor) in inputs {
            guard case .ndArray(let declared)? = descriptor.inputDescriptor(of: name) else {
                throw InferenceError.invalidTensor("the model has no tensor input '\(name)'")
            }
            if arrays[name]?.shape != tensor.shape {
                arrays[name] = NDArray(shape: tensor.shape, scalarType: declared.scalarType)
            }
            try write(tensor, into: &arrays[name]!, scalarType: declared.scalarType)
        }
        return arrays
    }

    private func write(_ tensor: Tensor, into array: inout NDArray, scalarType: NDArray.ScalarType) throws {
        switch (tensor.element, scalarType) {
        case (.float32, .float16):
            array.mutableRawView().withUnsafeMutableBytes { dst, shape, strides in
                let rowLength = shape[shape.count - 1]
                tensor.bytes.withUnsafeBytes { raw in
                    let src = raw.baseAddress!.assumingMemoryBound(to: Float.self)
                    forEachRow(shape: shape, strides: strides) { row, offset in
                        var s = vImage_Buffer(data: .init(mutating: src + row * rowLength), height: 1,
                                              width: vImagePixelCount(rowLength), rowBytes: rowLength * 4)
                        var d = vImage_Buffer(data: dst + offset * 2, height: 1,
                                              width: vImagePixelCount(rowLength), rowBytes: rowLength * 2)
                        vImageConvert_PlanarFtoPlanar16F(&s, &d, 0)
                    }
                }
            }
        case (.float32, .float32), (.int32, .int32):
            array.mutableRawView().withUnsafeMutableBytes { dst, shape, strides in
                let rowLength = shape[shape.count - 1]
                tensor.bytes.withUnsafeBytes { raw in
                    forEachRow(shape: shape, strides: strides) { row, offset in
                        (dst + offset * 4).copyMemory(from: raw.baseAddress! + row * rowLength * 4,
                                                      byteCount: rowLength * 4)
                    }
                }
            }
        default:
            throw InferenceError.invalidTensor(
                "the model wants \(scalarType) where the caller passed \(tensor.element.rawValue)")
        }
    }

    /// Visits every innermost row in row-major order with its element offset under `strides`.
    private func forEachRow(shape: Span<Int>, strides: Span<Int>, _ body: (Int, Int) -> Void) {
        let dims = Array(0..<shape.count).map { shape[$0] }
        let steps = Array(0..<strides.count).map { strides[$0] }
        guard let rowLength = dims.last, rowLength > 0 else { return }
        let rows = dims.reduce(1, *) / rowLength
        var index = [Int](repeating: 0, count: dims.count - 1)
        for row in 0..<rows {
            var offset = 0
            for d in 0..<index.count { offset += index[d] * steps[d] }
            body(row, offset)
            var d = index.count - 1
            while d >= 0 {
                index[d] += 1
                if index[d] < dims[d] { break }
                index[d] = 0
                d -= 1
            }
        }
    }

    private func tensor(from array: NDArray) throws -> Tensor {
        let shape = array.shape
        switch array.scalarType {
        case .float16:
            let halves: [Float16] = array.view(as: Float16.self).withUnsafePointer { base, shape, strides in
                gather(base, shape: shape, strides: strides)
            }
            var floats = [Float](repeating: 0, count: halves.count)
            halves.withUnsafeBytes { src in
                floats.withUnsafeMutableBytes { dst in
                    var s = vImage_Buffer(data: .init(mutating: src.baseAddress!), height: 1,
                                          width: vImagePixelCount(halves.count), rowBytes: halves.count * 2)
                    var d = vImage_Buffer(data: dst.baseAddress!, height: 1,
                                          width: vImagePixelCount(halves.count), rowBytes: halves.count * 4)
                    vImageConvert_Planar16FtoPlanarF(&s, &d, 0)
                }
            }
            return Tensor(float32: floats, shape: shape)
        case .float32:
            let floats: [Float] = array.view(as: Float.self).withUnsafePointer { base, shape, strides in
                gather(base, shape: shape, strides: strides)
            }
            return Tensor(float32: floats, shape: shape)
        case .int32:
            let ints: [Int32] = array.view(as: Int32.self).withUnsafePointer { base, shape, strides in
                gather(base, shape: shape, strides: strides)
            }
            return Tensor(int32: ints, shape: shape)
        default:
            throw InferenceError.runFailed("unsupported output scalar type \(array.scalarType)")
        }
    }

    /// Row-major copy that honors the runtime's strides, which pad the innermost row on the ANE.
    private func gather<T>(_ base: UnsafePointer<T>, shape: Span<Int>, strides: Span<Int>) -> [T] {
        let count = Array(0..<shape.count).map { shape[$0] }.reduce(1, *)
        let rowLength = shape.count > 0 ? shape[shape.count - 1] : 0
        return [T](unsafeUninitializedCapacity: count) { buffer, filled in
            forEachRow(shape: shape, strides: strides) { row, offset in
                (buffer.baseAddress! + row * rowLength).update(from: base + offset, count: rowLength)
            }
            filled = count
        }
    }

    private static func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached(priority: .userInitiated) {
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var result: Result<T, Error>?
    }
}
#endif
