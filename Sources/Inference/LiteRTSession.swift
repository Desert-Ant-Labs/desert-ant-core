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

    init(modelPath: String, modelBytes: [UInt8]? = nil,
         accelerator: LiteRTSession.Accelerator = .auto) throws {
        var errbuf = [CChar](repeating: 0, count: 256)
        let handle: OpaquePointer? = errbuf.withUnsafeMutableBufferPointer { err in
            if let modelBytes {
                return modelBytes.withUnsafeBytes { bytes in
                    dal_lrt_model_create(nil, bytes.baseAddress, bytes.count,
                                         accelerator.rawValue, 0, 0,
                                         err.baseAddress, Int32(err.count))
                }
            } else {
                return modelPath.withCString { path in
                    dal_lrt_model_create(path, nil, 0, accelerator.rawValue, 0, 0,
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
        inputNames = (0..<Int(dal_lrt_num_inputs(handle))).map {
            dal_lrt_input_name(handle, Int32($0)).map(decodeCString) ?? ""
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

    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) throws -> [Tensor] {
        model.lock.lock()
        defer { model.lock.unlock() }
        // Assemble input byte buffers in the model's declared input order.
        var buffers: [[UInt8]] = []
        buffers.reserveCapacity(inputNames.count)
        for name in inputNames {
            guard let tensor = inputs[name] else {
                throw InferenceError.invalidTensor("missing input '\(name)'")
            }
            buffers.append(tensor.bytes)
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

        let element: Tensor.Element
        switch dal_lrt_output_element_type(session, index) {
        case 1: element = .float32
        case 2: element = .int32
        case 4: element = .int64
        default: throw InferenceError.runFailed("unsupported LiteRT output element type")
        }
        return try Tensor(element: element, shape: shape, bytes: bytes)
    }
}

#endif
