#if canImport(COnnxRuntime) && !canImport(CoreML)
import COnnxRuntime
import Foundation

/// The ONNX Runtime engine: three graphs, driven with the same preallocated
/// buffers Core ML binds, through a run that writes its outputs straight into
/// them.
///
/// On Windows the accelerator is DirectML, and it is the reason this exists.
/// Measured on a Radeon 8060S over 37 s of speech, Voz runs end to end at 366x
/// real time on the GPU against 38.7x on the CPU provider, on the same float16
/// weights and with a character-identical transcript. The NPU was tried first
/// and is not the fast path: it needs int8 weights, the encoder's attention
/// crashes its compiler outright, and at its best it measured no quicker than
/// the CPU.
///
/// The models are exported with the same signatures Core ML uses, so the
/// pipeline above is unchanged. That is deliberate: `scripts/export_wasm.py` in
/// voz-training fuses the mel into the encoder and reduces the decode step's
/// argmax into the graph, both of which suit a browser and neither of which
/// fits `Engine`.
final class OnnxEngine: Engine {
    let decodeLanes: Int

    private let mel: Model
    private let encoder: Model
    private let decodeStep: Model

    /// One loaded graph, with its I/O bound by pointer.
    private final class Model {
        let session: OpaquePointer
        let name: String

        init(path: String, accelerator: Int32) throws {
            name = (path as NSString).lastPathComponent
            var errbuf = [CChar](repeating: 0, count: 512)
            let handle: OpaquePointer? = errbuf.withUnsafeMutableBufferPointer { err in
                path.withCString { p in
                    dal_ort_create(p, accelerator, nil, err.baseAddress, Int32(err.count))
                }
            }
            guard let handle else {
                throw VozError.invalidModel(
                    "could not load \((path as NSString).lastPathComponent): "
                    + String(cString: errbuf))
            }
            session = handle
        }

        deinit { dal_ort_free(session) }

        /// Run with every tensor bound to a `Buffer`, in the model's declared
        /// order. Nothing is copied on the way in, and ORT writes the results
        /// through the output buffers' own pointers.
        func run(inputs: [Buffer], outputs: [Buffer]) throws {
            let rank = Int(DAL_ORT_MAX_RANK)
            var inPtrs = inputs.map { UnsafeRawPointer($0.ptr) as UnsafeRawPointer? }
            var inLens = inputs.map { $0.count * MemoryLayout<Element>.stride }
            var inDims = [Int64](repeating: 0, count: inputs.count * rank)
            var inRanks = [Int32]()
            var outPtrs = outputs.map { UnsafeMutableRawPointer($0.ptr) as UnsafeMutableRawPointer? }
            var outLens = outputs.map { $0.count * MemoryLayout<Element>.stride }
            var outDims = [Int64](repeating: 0, count: outputs.count * rank)
            var outRanks = [Int32]()
            for (i, b) in inputs.enumerated() {
                for (d, extent) in b.shape.enumerated() { inDims[i * rank + d] = Int64(extent) }
                inRanks.append(Int32(b.shape.count))
            }
            for (i, b) in outputs.enumerated() {
                for (d, extent) in b.shape.enumerated() { outDims[i * rank + d] = Int64(extent) }
                outRanks.append(Int32(b.shape.count))
            }
            // Every model-facing buffer is float32 off Apple, which is code 1.
            let inElements = [Int32](repeating: 1, count: inputs.count)
            let outElements = [Int32](repeating: 1, count: outputs.count)

            var errbuf = [CChar](repeating: 0, count: 512)
            let status: Int32 = errbuf.withUnsafeMutableBufferPointer { err in
                inPtrs.withUnsafeBufferPointer { ip in
                    inLens.withUnsafeBufferPointer { il in
                        inDims.withUnsafeBufferPointer { id in
                            inRanks.withUnsafeBufferPointer { ir in
                                inElements.withUnsafeBufferPointer { ie in
                                    outPtrs.withUnsafeBufferPointer { op in
                                        outLens.withUnsafeBufferPointer { ol in
                                            outDims.withUnsafeBufferPointer { od in
                                                outRanks.withUnsafeBufferPointer { orr in
                                                    outElements.withUnsafeBufferPointer { oe in
                                                        dal_ort_run_bound(
                                                            session,
                                                            ip.baseAddress, il.baseAddress,
                                                            id.baseAddress, ir.baseAddress,
                                                            ie.baseAddress, Int32(inputs.count),
                                                            op.baseAddress, ol.baseAddress,
                                                            od.baseAddress, orr.baseAddress,
                                                            oe.baseAddress, Int32(outputs.count),
                                                            err.baseAddress, Int32(err.count))
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            guard status == 0 else {
                throw VozError.invalidModel("\(name) failed: " + String(cString: errbuf))
            }
        }
    }

    /// Which hardware to ask for. `.gpu` is the default because it is the only
    /// setting that makes this worth using.
    enum Accelerator: Int32, Sendable {
        case cpu = 1
        case gpu = 2
    }

    init(directory: URL, accelerator: Accelerator = .gpu, lanes: Int) throws {
        func path(_ name: String) throws -> String {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VozError.invalidModel("missing \(name) in \(directory.path)")
            }
            return url.path
        }
        mel = try Model(path: try path("mel.onnx"), accelerator: accelerator.rawValue)
        encoder = try Model(path: try path("encoder.onnx"), accelerator: accelerator.rawValue)
        decodeStep = try Model(path: try path("decoder.onnx"), accelerator: accelerator.rawValue)
        decodeLanes = lanes
    }

    func runMel(rows: Buffer, melMask: Buffer, mel out: Buffer,
                isolation: isolated (any Actor)?) async throws {
        try mel.run(inputs: [rows, melMask], outputs: [out])
    }

    /// `padMask` is deliberately unused. The [B, T, C] encoder masks through
    /// `key_bias` alone, so the traced graph has no pad_mask input at all -
    /// torch prunes it, because the module takes it and never reads it. The
    /// Core ML engine still passes one, and the buffer is all ones either way;
    /// see the note in `PipelineBuffers` for why zeroing it would be wrong.
    func runEncoder(mel input: Buffer, keyBias: Buffer, padMask: Buffer, encOut: Buffer,
                    isolation: isolated (any Actor)?) async throws {
        try encoder.run(inputs: [input, keyBias], outputs: [encOut])
    }

    func runDecodeStep(embed: Buffer, hIn: Buffer, cIn: Buffer, encStep: Buffer,
                       logits: Buffer, hOut: Buffer, cOut: Buffer,
                       isolation: isolated (any Actor)?) async throws {
        try decodeStep.run(inputs: [embed, hIn, cIn, encStep], outputs: [logits, hOut, cOut])
    }
}
#endif
