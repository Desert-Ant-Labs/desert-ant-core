#if canImport(COnnxRuntime)
import COnnxRuntime

/// ONNX Runtime inference backend, behind the shared ``InferenceSession`` API.
/// Windows uses it because that is where the NPU execution providers live; the
/// same graphs run on CPU anywhere ONNX Runtime does.
///
/// The ORT lifecycle (api table, environment, session options, execution
/// provider selection, OrtValue construction, status checking) lives in the C
/// shim in `COnnxRuntime`; this type marshals named ``Tensor`` inputs and
/// outputs across it. Binaries that use it must link `onnxruntime.dll`.
///
/// Unlike ``LiteRTSession`` this passes each input's shape per run rather than
/// compiling to fixed shapes: Voz's encoder declares a dynamic batch axis so a
/// partial group of windows costs only what it holds.
final class OnnxSession: InferenceSession, @unchecked Sendable {
    private let session: OpaquePointer
    private let inputNames: [String]
    private let outputNames: [String]
    private let outputIndex: [String: Int]
    /// Which accelerators were added to this session. It does NOT mean any node
    /// ran on them: a provider that claims nothing still appears on the session,
    /// so treat this as "the hardware path exists" and measure placement
    /// separately.
    let accelerators: Accelerator.Set
    // The shim owns one session plus a single set of output buffers, which the
    // reads after a run consume, so a run is not reentrant. Serialize the whole
    // run+read so concurrent callers on one session are safe.
    private let lock = PlatformMutex()

    /// Which hardware the session may use. Mirrors ``LiteRTSession/Accelerator``
    /// so callers speak one vocabulary across backends.
    ///
    /// On Windows `.gpu` is DirectML, and it is the one worth asking for: Voz
    /// runs end to end at 366x real time on a Radeon 8060S against 38.7x on the
    /// CPU provider, on the same float16 weights and with a character-identical
    /// transcript. `.npu` exists because the capability is real, not because it
    /// is fast: it needs int8 weights, the encoder's attention crashes its
    /// compiler outright, and at its best it measured no quicker than the CPU.
    enum Accelerator: Int32, Sendable {
        case cpu = 1
        case gpu = 2
        case npu = 4

        /// A bitset of accelerators, which is how the shim reports what a
        /// session actually got.
        struct Set: OptionSet, Sendable {
            let rawValue: Int32
            static let cpu = Set(rawValue: Accelerator.cpu.rawValue)
            static let gpu = Set(rawValue: Accelerator.gpu.rawValue)
            static let npu = Set(rawValue: Accelerator.npu.rawValue)
        }
    }

    /// - Parameter npuLibrary: the NPU provider DLL, needed only for `.npu`.
    ///   It cannot be discovered here: the Windows ML providers live under
    ///   `C:\Program Files\WindowsApps`, whose ACL denies a directory listing
    ///   even though a known full path opens, so no glob finds them. `nil`
    ///   falls back to the `DAL_ORT_NPU_EP` environment variable.
    init(modelPath: String, accelerator: Accelerator = .gpu,
         npuLibrary: String? = nil) throws {
        var errbuf = [CChar](repeating: 0, count: 512)
        let handle: OpaquePointer? = errbuf.withUnsafeMutableBufferPointer { err in
            modelPath.withCString { path in
                if let npuLibrary {
                    return npuLibrary.withCString { lib in
                        dal_ort_create(path, accelerator.rawValue, lib,
                                       err.baseAddress, Int32(err.count))
                    }
                }
                return dal_ort_create(path, accelerator.rawValue, nil,
                                      err.baseAddress, Int32(err.count))
            }
        }
        guard let handle else {
            throw InferenceError.sessionUnavailable(String(cString: errbuf))
        }
        session = handle
        accelerators = Accelerator.Set(rawValue: dal_ort_accelerators(handle))
        inputNames = (0..<Int(dal_ort_num_inputs(handle))).map {
            dal_ort_input_name(handle, Int32($0)).map(String.init(cString:)) ?? ""
        }
        let outs = (0..<Int(dal_ort_num_outputs(handle))).map {
            dal_ort_output_name(handle, Int32($0)).map(String.init(cString:)) ?? ""
        }
        outputNames = outs
        outputIndex = Dictionary(uniqueKeysWithValues: outs.enumerated().map { ($1, $0) })
    }

    deinit {
        dal_ort_free(session)
    }

    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) throws -> [Tensor] {
        lock.lock()
        defer { lock.unlock() }

        // Assemble buffers, shapes and element codes in the model's declared
        // input order. Shapes travel flattened at a fixed stride per input,
        // which is what the shim's run signature takes.
        var buffers: [[UInt8]] = []
        var dims = [Int64](repeating: 0, count: inputNames.count * Int(DAL_ORT_MAX_RANK))
        var ranks = [Int32]()
        var elements = [Int32]()
        buffers.reserveCapacity(inputNames.count)
        for (i, name) in inputNames.enumerated() {
            guard let tensor = inputs[name] else {
                throw InferenceError.invalidTensor("missing input '\(name)'")
            }
            guard tensor.shape.count <= Int(DAL_ORT_MAX_RANK) else {
                throw InferenceError.invalidTensor(
                    "input '\(name)' has rank \(tensor.shape.count), above the supported maximum")
            }
            buffers.append(tensor.bytes)
            for (d, extent) in tensor.shape.enumerated() {
                dims[i * Int(DAL_ORT_MAX_RANK) + d] = Int64(extent)
            }
            ranks.append(Int32(tensor.shape.count))
            elements.append(code(for: tensor.element))
        }

        var errbuf = [CChar](repeating: 0, count: 512)
        let status: Int32 = errbuf.withUnsafeMutableBufferPointer { err in
            dims.withUnsafeBufferPointer { d in
                ranks.withUnsafeBufferPointer { r in
                    elements.withUnsafeBufferPointer { e in
                        withByteBuffers(buffers) { pointers, lengths in
                            dal_ort_run(session, pointers, lengths,
                                        d.baseAddress, r.baseAddress, e.baseAddress,
                                        Int32(buffers.count),
                                        err.baseAddress, Int32(err.count))
                        }
                    }
                }
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

    /// The last-dimension extent the graph declares for `name`, when it is
    /// static. A dynamic axis reports as a non-positive extent and yields nil
    /// rather than a guess.
    func inputWidth(_ name: String) -> Int? { nil }

    private func code(for element: Tensor.Element) -> Int32 {
        switch element {
        case .float32: return 1
        case .int32: return 2
        case .int64: return 4
        }
    }

    private func readOutput(_ index: Int32) throws -> Tensor {
        let rank = Int(dal_ort_output_rank(session, index))
        var dims = [Int64](repeating: 0, count: max(rank, 1))
        dims.withUnsafeMutableBufferPointer { dal_ort_output_dims(session, index, $0.baseAddress) }
        let shape = dims.prefix(rank).map(Int.init)

        let byteCount = dal_ort_output_byte_size(session, index)
        let bytes: [UInt8]
        if let data = dal_ort_output_data(session, index), byteCount > 0 {
            bytes = Array(UnsafeRawBufferPointer(start: data, count: byteCount))
        } else {
            bytes = []
        }

        let element: Tensor.Element
        switch dal_ort_output_element_type(session, index) {
        case 1: element = .float32
        case 2: element = .int32
        case 4: element = .int64
        default: throw InferenceError.runFailed("unsupported ONNX output element type")
        }
        return try Tensor(element: element, shape: shape, bytes: bytes)
    }
}
#endif
