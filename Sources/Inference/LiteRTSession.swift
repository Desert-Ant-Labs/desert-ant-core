#if canImport(CLiteRt)
import CLiteRt
import CStrings
#if os(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// One compiled `.tflite`, shared by sessions over its signatures, so a model
/// with several (one per task) loads and packs its weights once. LiteRT does not
/// run a compiled model reentrantly, even on different signatures, so every
/// session of a model runs under the model's lock.
final class LiteRTModel: @unchecked Sendable {
    let handle: OpaquePointer
    let lock = PlatformMutex()
    /// The signature keys, in the model's order.
    let signatures: [String]

    /// GPU compute precision (LiteRtDelegatePrecision): fp16 math with fp32
    /// accumulation. LiteRT's default accumulates in fp16 too, which on Adreno
    /// moved Eye's photo heads far off the CPU (issue #101); this brings them
    /// back for about a quarter more GPU time there. CPU sessions ignore it.
    static let gpuPrecision: Int32 = 3

    init(modelPath: String, modelBytes: [UInt8]? = nil,
         accelerator: LiteRTSession.Accelerator = .auto) throws {
        var errbuf = [CChar](repeating: 0, count: 256)
        let handle: OpaquePointer? = errbuf.withUnsafeMutableBufferPointer { err in
            if let modelBytes {
                return modelBytes.withUnsafeBytes { bytes in
                    dal_lrt_model_create(nil, bytes.baseAddress, bytes.count,
                                         accelerator.rawValue, 0, Self.gpuPrecision,
                                         err.baseAddress, Int32(err.count))
                }
            } else {
                return modelPath.withCString { path in
                    dal_lrt_model_create(path, nil, 0, accelerator.rawValue, 0, Self.gpuPrecision,
                                         err.baseAddress, Int32(err.count))
                }
            }
        }
        guard let handle else {
            throw InferenceError.sessionUnavailable(decodeCString(errbuf))
        }
        self.handle = handle
        signatures = (0..<Int(dal_lrt_model_num_signatures(handle))).map {
            dal_lrt_model_signature_key(handle, Int32($0)).map(decodeCString) ?? ""
        }
    }

    deinit {
        dal_lrt_model_release(handle)
    }
}

/// LiteRT (formerly TensorFlow Lite) inference backend (Android / Linux) over
/// the LiteRT C API, behind the shared ``InferenceSession`` API. Load from a
/// `.tflite` file path or from in-memory model bytes (e.g. classpath resources
/// on Android). Binaries that use it must link `libLiteRt.so` for the target
/// platform.
///
/// The intricate LiteRT lifecycle (environment, model, compiled model, tensor
/// buffer requirements, lock/unlock) lives in the C shim in `CLiteRt`; this type
/// marshals named ``Tensor`` inputs and outputs across it. Hardware acceleration
/// (XNNPACK on CPU by default; GPU/NPU when requested) is selected in the shim.
/// A session runs one signature; ``init(model:signature:)`` opens another
/// signature of an already compiled model.
final class LiteRTSession: InferenceSession, @unchecked Sendable {
    private let session: OpaquePointer
    private let inputNames: [String]
    /// Each input's declared element type and shape, in `inputNames` order.
    /// `nil` element: a type ``Tensor`` cannot carry (the run rejects it).
    private let inputElements: [Tensor.Element?]
    private let inputShapes: [[Int]]
    private let outputNames: [String]
    private let outputIndex: [String: Int]
    // The model's compiled model and this session's fixed-shape host buffers are
    // not reentrant, so a run (and the output reads that follow it, which read
    // those same buffers) holds the model's lock: concurrent callers on one
    // session, or on sessions of one model, are safe.
    private let model: LiteRTModel

    /// LiteRT hardware accelerator bitset (mirrors LiteRtHwAccelerators): 1 =
    /// CPU, 2 = GPU, 4 = NPU. `.auto` (GPU|CPU) prefers the GPU and falls back
    /// to CPU: the GPU is used automatically when its accelerator library is
    /// bundled with the app and usable, otherwise the model runs on CPU
    /// (XNNPACK). The C shim retries CPU-only if compiling for the GPU fails, so
    /// requesting the GPU is always safe.
    enum Accelerator: Int32, Sendable {
        case cpu = 1
        case gpu = 2
        case npu = 4
        /// Prefer the GPU when its accelerator library is present; else CPU.
        case auto = 3   // gpu | cpu
    }

    /// A model of its own, run at its first signature.
    convenience init(modelPath: String, modelBytes: [UInt8]? = nil,
                     accelerator: Accelerator = .auto) throws {
        try self.init(model: LiteRTModel(modelPath: modelPath, modelBytes: modelBytes,
                                         accelerator: accelerator), signature: nil)
    }

    /// One signature of `model`, by key (`nil`: the first).
    init(model: LiteRTModel, signature: String?) throws {
        var errbuf = [CChar](repeating: 0, count: 256)
        let handle: OpaquePointer? = errbuf.withUnsafeMutableBufferPointer { err in
            if let signature {
                return signature.withCString {
                    dal_lrt_session_create(model.handle, $0, err.baseAddress, Int32(err.count))
                }
            }
            return dal_lrt_session_create(model.handle, nil, err.baseAddress, Int32(err.count))
        }
        guard let handle else {
            throw InferenceError.sessionUnavailable(
                "\(decodeCString(errbuf))\(signature.map { " ('\($0)')" } ?? "")")
        }
        self.model = model
        session = handle
        let inputCount = Int(dal_lrt_num_inputs(handle))
        inputNames = (0..<inputCount).map {
            dal_lrt_input_name(handle, Int32($0)).map(decodeCString) ?? ""
        }
        inputElements = (0..<inputCount).map {
            Self.element(dal_lrt_input_element_type(handle, Int32($0)))
        }
        inputShapes = (0..<inputCount).map { index in
            let rank = Int(dal_lrt_input_rank(handle, Int32(index)))
            var dims = [Int32](repeating: 0, count: max(rank, 1))
            dims.withUnsafeMutableBufferPointer { dal_lrt_input_dims(handle, Int32(index), $0.baseAddress) }
            return dims.prefix(rank).map(Int.init)
        }
        let outs = (0..<Int(dal_lrt_num_outputs(handle))).map {
            dal_lrt_output_name(handle, Int32($0)).map(decodeCString) ?? ""
        }
        outputNames = outs
        outputIndex = Dictionary(uniqueKeysWithValues: outs.enumerated().map { ($1, $0) })
    }

    deinit {
        dal_lrt_free(session)
    }

    /// The shim's element codes are `LiteRtElementType`: 1 float32, 2 int32, 4 int64.
    private static func element(_ code: Int32) -> Tensor.Element? {
        switch code {
        case 1: return .float32
        case 2: return .int32
        case 4: return .int64
        default: return nil
        }
    }

    func inputWidth(_ name: String) -> Int? {
        guard let index = inputNames.firstIndex(of: name),
              let width = inputShapes[index].last, width > 0 else { return nil }
        return width
    }

    /// `tensor`'s bytes in the layout input `index` declares.
    ///
    /// The shim copies at most the buffer's size and never complains, so a
    /// mismatch here would run on garbage rather than fail: an int32 batch fed to
    /// an int64 graph fills half the buffer with pairs of ids. So the element
    /// type and count are checked, and the one lossless conversion is made:
    /// int32 widened to int64. Exporters disagree on index types (the clips
    /// `.tflite` files take int64 ids where Core ML takes int32), and widening
    /// here keeps that out of every model's code.
    private func bytes(of tensor: Tensor, forInput index: Int) throws -> [UInt8] {
        let name = inputNames[index]
        guard let declared = inputElements[index] else {
            throw InferenceError.invalidTensor("input '\(name)' has an element type Tensor cannot carry")
        }
        // A dynamic dimension (-1) has no count to check against up front.
        let shape = inputShapes[index]
        guard shape.contains(where: { $0 <= 0 }) || tensor.count == shape.reduce(1, *) else {
            throw InferenceError.invalidTensor(
                "input '\(name)' takes \(inputShapes[index]), got \(tensor.shape)")
        }
        switch (tensor.element, declared) {
        case let (given, wanted) where given == wanted:
            return tensor.bytes
        case (.int32, .int64):
            let wide = (tensor.int32Values ?? []).map(Int64.init)
            return wide.withUnsafeBytes { Array($0) }
        default:
            throw InferenceError.invalidTensor(
                "input '\(name)' takes \(declared.rawValue), got \(tensor.element.rawValue)")
        }
    }

    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) throws -> [Tensor] {
        model.lock.lock()
        defer { model.lock.unlock() }
        // Assemble input byte buffers in the model's declared input order.
        var buffers: [[UInt8]] = []
        buffers.reserveCapacity(inputNames.count)
        for (index, name) in inputNames.enumerated() {
            guard let tensor = inputs[name] else {
                throw InferenceError.invalidTensor("missing input '\(name)'")
            }
            buffers.append(try bytes(of: tensor, forInput: index))
        }

        var errbuf = [CChar](repeating: 0, count: 256)
        let status: Int32 = errbuf.withUnsafeMutableBufferPointer { err in
            withByteBuffers(buffers) { pointers, lengths in
                dal_lrt_run(session, pointers, lengths, Int32(buffers.count),
                            err.baseAddress, Int32(err.count))
            }
        }
        guard status == 0 else {
            throw InferenceError.runFailed(decodeCString(errbuf))
        }

        return try outputs.map { name in
            guard let index = outputIndex[name] else {
                throw InferenceError.runFailed("the model has no output '\(name)'")
            }
            return try readOutput(Int32(index))
        }
    }

    private func readOutput(_ index: Int32) throws -> Tensor {
        let rank = Int(dal_lrt_output_rank(session, index))
        var dims = [Int32](repeating: 0, count: max(rank, 1))
        dims.withUnsafeMutableBufferPointer { dal_lrt_output_dims(session, index, $0.baseAddress) }
        let shape = dims.prefix(rank).map(Int.init)

        let byteCount = dal_lrt_output_byte_size(session, index)
        let bytes: [UInt8]
        if let data = dal_lrt_output_data(session, index), byteCount > 0 {
            bytes = Array(UnsafeRawBufferPointer(start: data, count: byteCount))
        } else {
            bytes = []
        }

        guard let element = Self.element(dal_lrt_output_element_type(session, index)) else {
            throw InferenceError.runFailed("unsupported LiteRT output element type")
        }
        return try Tensor(element: element, shape: shape, bytes: bytes)
    }
}

#endif
