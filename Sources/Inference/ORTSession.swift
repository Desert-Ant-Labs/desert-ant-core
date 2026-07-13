#if canImport(COnnxRuntime)
import COnnxRuntime

/// ONNX Runtime inference backend (Android / Linux) over the ORT C API, behind
/// the shared ``InferenceSession`` API. Load from a file path or from
/// in-memory model bytes (e.g. classpath resources on Android). Binaries that
/// use it must link `libonnxruntime.so` for the target platform.
public final class ORTSession: InferenceSession, @unchecked Sendable {
    private let api: OrtApi
    private var env: OpaquePointer?
    private var session: OpaquePointer?
    private var memoryInfo: OpaquePointer?

    public init(modelPath: String, modelBytes: [UInt8]? = nil) throws {
        guard let base = OrtGetApiBase(), let apiPointer = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            throw InferenceError.sessionUnavailable("ONNX Runtime C API unavailable")
        }
        api = apiPointer.pointee
        try check(api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "desert-ant", &env))
        var options: OpaquePointer?
        try check(api.CreateSessionOptions(&options))
        defer { api.ReleaseSessionOptions(options) }
        if let modelBytes {
            try modelBytes.withUnsafeBytes { buffer in
                try check(api.CreateSessionFromArray(env, buffer.baseAddress, buffer.count, options, &session))
            }
        } else {
            try check(api.CreateSession(env, modelPath, options, &session))
        }
        try check(api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memoryInfo))
    }

    deinit {
        if let session { api.ReleaseSession(session) }
        if let memoryInfo { api.ReleaseMemoryInfo(memoryInfo) }
        if let env { api.ReleaseEnv(env) }
    }

    public func run(inputs: [String: Tensor], outputs: [String]) throws -> [Tensor] {
        let names = Array(inputs.keys)
        var inputValues: [OpaquePointer?] = Array(repeating: nil, count: names.count)
        var buffers: [UnsafeMutableRawBufferPointer] = []
        defer {
            for value in inputValues where value != nil { api.ReleaseValue(value) }
            for buffer in buffers { buffer.deallocate() }
        }
        for (index, name) in names.enumerated() {
            let tensor = inputs[name]!
            // ORT borrows the data for the duration of Run, so give it stable
            // storage rather than a closure-scoped pointer.
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: tensor.bytes.count, alignment: 16)
            buffer.copyBytes(from: tensor.bytes)
            buffers.append(buffer)
            let shape = tensor.shape.map { Int64($0) }
            try shape.withUnsafeBufferPointer { dims in
                try check(api.CreateTensorWithDataAsOrtValue(
                    memoryInfo, buffer.baseAddress, buffer.count,
                    dims.baseAddress, shape.count, elementType(tensor.element), &inputValues[index]))
            }
        }

        var outputValues: [OpaquePointer?] = Array(repeating: nil, count: outputs.count)
        defer { for value in outputValues where value != nil { api.ReleaseValue(value) } }
        let inputNames = names.map(cString)
        let outputNames = outputs.map(cString)
        defer { for name in inputNames + outputNames { name.deallocate() } }
        var inputNamePointers: [UnsafePointer<CChar>?] = inputNames.map { UnsafePointer($0) }
        var outputNamePointers: [UnsafePointer<CChar>?] = outputNames.map { UnsafePointer($0) }
        try inputNamePointers.withUnsafeMutableBufferPointer { inNames in
            try outputNamePointers.withUnsafeMutableBufferPointer { outNames in
                try inputValues.withUnsafeBufferPointer { values in
                    try outputValues.withUnsafeMutableBufferPointer { results in
                        try check(api.Run(
                            session, nil, inNames.baseAddress, values.baseAddress, names.count,
                            outNames.baseAddress, outputs.count, results.baseAddress))
                    }
                }
            }
        }
        return try outputValues.map { try tensor(from: $0) }
    }

    private func check(_ status: OrtStatusPtr?) throws {
        guard let status else { return }
        let message = api.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown ONNX Runtime error"
        api.ReleaseStatus(status)
        throw InferenceError.runFailed(message)
    }

    private func cString(_ string: String) -> UnsafeMutablePointer<CChar> {
        let utf8 = Array(string.utf8CString)
        let pointer = UnsafeMutablePointer<CChar>.allocate(capacity: utf8.count)
        pointer.initialize(from: utf8, count: utf8.count)
        return pointer
    }

    private func elementType(_ element: Tensor.Element) -> ONNXTensorElementDataType {
        switch element {
        case .int32: return ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32
        case .int64: return ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64
        case .float32: return ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT
        }
    }

    private func tensor(from value: OpaquePointer?) throws -> Tensor {
        guard let value else { throw InferenceError.runFailed("missing model output") }
        var info: OpaquePointer?
        try check(api.GetTensorTypeAndShape(value, &info))
        defer { if info != nil { api.ReleaseTensorTypeAndShapeInfo(info) } }
        var rawType = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
        try check(api.GetTensorElementType(info, &rawType))
        let element: Tensor.Element
        if rawType == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT {
            element = .float32
        } else if rawType == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32 {
            element = .int32
        } else if rawType == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 {
            element = .int64
        } else {
            throw InferenceError.runFailed("unsupported output element type \(rawType.rawValue)")
        }
        var dimensions: size_t = 0
        try check(api.GetDimensionsCount(info, &dimensions))
        var shape = [Int64](repeating: 0, count: Int(dimensions))
        try check(api.GetDimensions(info, &shape, dimensions))
        var elementCount: size_t = 0
        try check(api.GetTensorShapeElementCount(info, &elementCount))
        var data: UnsafeMutableRawPointer?
        try check(api.GetTensorMutableData(value, &data))
        guard let data else { throw InferenceError.runFailed("model output has no data") }
        let bytes = Array(UnsafeRawBufferPointer(start: data, count: Int(elementCount) * element.stride))
        return try Tensor(element: element, shape: shape.map(Int.init), bytes: bytes)
    }
}
#endif
