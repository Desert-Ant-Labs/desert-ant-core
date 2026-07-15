#if DAL_LITERT
import CLiteRt
#if os(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

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
public final class LiteRTSession: InferenceSession, @unchecked Sendable {
    private let session: OpaquePointer
    private let inputNames: [String]
    private let outputNames: [String]
    private let outputIndex: [String: Int]
    // The C shim owns one compiled model plus a single set of fixed-shape host
    // tensor buffers, so a run (and the output reads that follow it, which read
    // those same buffers) is not reentrant. Serialize the whole run+read so
    // concurrent callers on one session are safe, matching the reentrant
    // ``InferenceSession`` contract that ORTSession provides for free.
    private var lock = pthread_mutex_t()

    /// LiteRT hardware accelerator bitset (mirrors LiteRtHwAccelerators): 1 = CPU.
    public enum Accelerator: Int32, Sendable {
        case cpu = 1
        case gpu = 2
        case npu = 4
    }

    public init(modelPath: String, modelBytes: [UInt8]? = nil,
                accelerator: Accelerator = .cpu) throws {
        var errbuf = [CChar](repeating: 0, count: 256)
        let handle: OpaquePointer? = errbuf.withUnsafeMutableBufferPointer { err in
            if let modelBytes {
                return modelBytes.withUnsafeBytes { bytes in
                    dal_lrt_create(nil, bytes.baseAddress, bytes.count,
                                   accelerator.rawValue, err.baseAddress, Int32(err.count))
                }
            } else {
                return modelPath.withCString { path in
                    dal_lrt_create(path, nil, 0, accelerator.rawValue, err.baseAddress, Int32(err.count))
                }
            }
        }
        guard let handle else {
            throw InferenceError.sessionUnavailable(String(cString: errbuf))
        }
        session = handle
        inputNames = (0..<Int(dal_lrt_num_inputs(handle))).map {
            dal_lrt_input_name(handle, Int32($0)).map(String.init(cString:)) ?? ""
        }
        let outs = (0..<Int(dal_lrt_num_outputs(handle))).map {
            dal_lrt_output_name(handle, Int32($0)).map(String.init(cString:)) ?? ""
        }
        outputNames = outs
        outputIndex = Dictionary(uniqueKeysWithValues: outs.enumerated().map { ($1, $0) })
        pthread_mutex_init(&lock, nil)
    }

    deinit {
        dal_lrt_free(session)
        pthread_mutex_destroy(&lock)
    }

    public func run(inputs: [String: Tensor], outputs: [String]) throws -> [Tensor] {
        pthread_mutex_lock(&lock)
        defer { pthread_mutex_unlock(&lock) }
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
            throw InferenceError.runFailed(String(cString: errbuf))
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

/// Call `body` with parallel arrays of base pointers and byte lengths for
/// `buffers`, keeping every buffer pinned for the duration of the call.
private func withByteBuffers<R>(
    _ buffers: [[UInt8]],
    _ body: (_ pointers: UnsafePointer<UnsafeRawPointer?>, _ lengths: UnsafePointer<Int>) -> R
) -> R {
    func recurse(_ i: Int, _ pointers: inout [UnsafeRawPointer?], _ lengths: inout [Int]) -> R {
        if i == buffers.count {
            return pointers.withUnsafeBufferPointer { p in
                lengths.withUnsafeBufferPointer { l in body(p.baseAddress!, l.baseAddress!) }
            }
        }
        return buffers[i].withUnsafeBytes { raw in
            pointers[i] = raw.baseAddress
            lengths[i] = raw.count
            return recurse(i + 1, &pointers, &lengths)
        }
    }
    if buffers.isEmpty {
        return body(UnsafePointer(bitPattern: MemoryLayout<UnsafeRawPointer?>.alignment)!,
                    UnsafePointer(bitPattern: MemoryLayout<Int>.alignment)!)
    }
    var pointers = [UnsafeRawPointer?](repeating: nil, count: buffers.count)
    var lengths = [Int](repeating: 0, count: buffers.count)
    return recurse(0, &pointers, &lengths)
}
#endif
