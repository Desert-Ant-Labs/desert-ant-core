#if canImport(CLiteRt)
import CLiteRt
import Dispatch
import Foundation

/// The loaded model on Android/Linux: three LiteRT graphs plus the host-side
/// tables, behind the ``VozEngine`` seam the shared pipeline drives.
///
/// Drives the `CLiteRt` shim directly rather than going through
/// `InferenceSession`, for the same reason the Apple engine drives Core ML
/// directly: the decode loop dispatches hundreds of times per minute of audio,
/// and a marshalling API that copies every tensor per call is exactly the cost
/// the preallocated buffers exist to avoid. Inputs are pinned host buffers the
/// pipeline writes in place; outputs are copied out of the shim's fixed
/// buffers once per run.
///
/// I/O is float32, which is what a LiteRT export declares; the float16 story
/// that shapes the Apple engine is a Neural Engine concern. The one shared
/// float16 artifact, `embedding.f16`, is widened to float once at load.
///
/// Geometry comes from `meta.litert.json`, not the shared `meta.json`: the two
/// exports genuinely differ (this one decodes one lane at width 1), and the
/// Apple file would size every decode buffer wrong.
///
/// Tensors bind by position, not name: the export names every signature tensor
/// `args_N`/`output_N`, so names carry nothing to check. The order is the same
/// as the Apple providers' (mel: audio rows, mel mask; encoder: mel, key bias,
/// pad mask; decode: embed, h, c, enc step -> logits, h, c), and every binding
/// is checked against the declared shape at load, so a reordered export fails
/// loudly with the sizes rather than feeding the wrong tensor.
final class LiteRTAssets: VozEngine {
    typealias Element = Float

    let configuration: Configuration
    let vocabulary: [String]
    let decodeLanes: Int

    /// Row-major `[vocab + 1, predHidden]`, widened from the shipped float16.
    private let embedding: [Float]

    private let mel: Graph
    private let encoder: Graph
    private let decodeStep: Graph

    let rows: EngineBuffer<Float>
    let melMask: EngineBuffer<Float>
    let keyBias: EngineBuffer<Float>
    let encOut: EngineBuffer<Float>
    let embed: EngineBuffer<Float>
    let hIn: EngineBuffer<Float>
    let cIn: EngineBuffer<Float>
    let encStep: EngineBuffer<Float>
    let logitsOut: EngineBuffer<Float>
    let hOut: EngineBuffer<Float>
    let cOut: EngineBuffer<Float>
    /// Never crosses the engine seam: the mel output only exists to feed the
    /// encoder, and pad_mask is all ones forever (masking attention via
    /// keyBias alone is enough; see the Apple engine for the measured why).
    private let melOut: EngineBuffer<Float>
    private let padMask: EngineBuffer<Float>
    private var owned: [EngineBuffer<Float>] = []

    /// One compiled graph: the shim session plus this engine's buffer for each
    /// declared input (in the graph's input order) and output it reads back.
    ///
    /// A class rather than a struct for the timing counters alone: where a
    /// transcription spends its time is invisible from Kotlin, and "1x
    /// realtime" with no breakdown is undebuggable. Every run is counted and
    /// summarised to the platform log, cheaply enough to leave on: one clock
    /// read per dispatch and one log line per 15 s window (or 512 decode
    /// steps).
    private final class Graph {
        let session: OpaquePointer
        let inputs: [EngineBuffer<Float>]
        let outputs: [(index: Int32, into: EngineBuffer<Float>)]
        let name: String
        /// Log a summary every this many runs: 1 for the per-window graphs,
        /// larger for the decode step so it does not flood.
        let logEvery: Int
        private var runs = 0
        private var totalSeconds = 0.0
        private var sinceLog = 0.0

        init(session: OpaquePointer, inputs: [EngineBuffer<Float>],
             outputs: [(index: Int32, into: EngineBuffer<Float>)],
             name: String, logEvery: Int) {
            self.session = session
            self.inputs = inputs
            self.outputs = outputs
            self.name = name
            self.logEvery = logEvery
        }

        private func note(_ seconds: Double) {
            runs += 1
            totalSeconds += seconds
            sinceLog += seconds
            guard runs % logEvery == 0 else { return }
            dal_lrt_log(String(format: "voz %@: %d runs, %.3fs last %d, %.2fs total",
                               name, runs, sinceLog, logEvery, totalSeconds))
            sinceLog = 0
        }

        func run() throws {
            let started = DispatchTime.now().uptimeNanoseconds
            defer { note(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9) }
            var errbuf = [CChar](repeating: 0, count: 256)
            let pointers: [UnsafeRawPointer?] = inputs.map { UnsafeRawPointer($0.ptr) }
            let lengths: [Int] = inputs.map { $0.count * MemoryLayout<Float>.stride }
            let status = errbuf.withUnsafeMutableBufferPointer { err in
                pointers.withUnsafeBufferPointer { p in
                    lengths.withUnsafeBufferPointer { l in
                        dal_lrt_run(session, p.baseAddress, l.baseAddress,
                                    Int32(inputs.count), err.baseAddress, Int32(err.count))
                    }
                }
            }
            guard status == 0 else {
                throw VozError.invalidModel("inference failed: \(String(cString: errbuf))")
            }
            for (index, buffer) in outputs {
                let bytes = dal_lrt_output_byte_size(session, index)
                guard let data = dal_lrt_output_data(session, index),
                      bytes == buffer.count * MemoryLayout<Float>.stride else {
                    throw VozError.invalidModel(
                        "output \(index) returned \(bytes) bytes, expected "
                        + "\(buffer.count * MemoryLayout<Float>.stride)")
                }
                buffer.ptr.update(from: data.assumingMemoryBound(to: Float.self),
                                  count: buffer.count)
            }
        }
    }

    init(directory: URL) throws {
        let decoder = JSONDecoder()
        configuration = try decoder.decode(
            Configuration.self,
            from: try Data(contentsOf: directory.appendingPathComponent(VozModel.litertMeta)))
        try configuration.validate()
        vocabulary = try decoder.decode(
            [String].self,
            from: try Data(contentsOf: directory.appendingPathComponent("vocab.json")))
        guard vocabulary.count >= configuration.vocabSize else {
            throw VozError.invalidModel("vocabulary is smaller than the model's vocab size")
        }

        let raw = try Data(contentsOf: directory.appendingPathComponent("embedding.f16"))
        let expected = (configuration.vocabSize + 1) * configuration.predHidden
        guard raw.count == expected * 2 else {
            throw VozError.invalidModel(
                "embedding.f16 has \(raw.count) bytes, expected \(expected * 2)")
        }
        embedding = raw.withUnsafeBytes { bytes in
            bytes.bindMemory(to: UInt16.self).map(floatFromHalf)
        }

        func open(_ name: String, accelerator: Int32, threads: Int32 = 0) throws -> OpaquePointer {
            let path = directory.appendingPathComponent(name).path
            var errbuf = [CChar](repeating: 0, count: 256)
            let handle = errbuf.withUnsafeMutableBufferPointer { err in
                path.withCString {
                    dal_lrt_create($0, nil, 0, accelerator, threads,
                                   err.baseAddress, Int32(err.count))
                }
            }
            guard let handle else {
                throw VozError.invalidModel("\(name): \(String(cString: errbuf))")
            }
            return handle
        }
        // The mel and encoder are throughput-bound single dispatches, so they
        // take the GPU when its accelerator library is present (CPU fallback
        // is automatic). The decode step is the opposite shape of problem:
        // hundreds of tiny dispatches per minute of audio, where the GPU's
        // per-dispatch latency loses to XNNPACK on a graph this small - so it
        // is pinned to CPU deliberately, not by fallback.
        let melSession = try open(VozModel.melLiteRT, accelerator: 3 /* GPU|CPU */)
        let encoderSession = try open(VozModel.encoderLiteRT, accelerator: 3 /* GPU|CPU */)
        // One thread as well as CPU-only: a decode step is a few hundred
        // kiloflops, and a thread pool spends more per step waking and joining
        // workers than the work costs. Measured on a Pixel, the pool put the
        // whole decode phase near 60 ms per step against ~1.15 s for a full
        // encoder window.
        let stepSession = try open(VozModel.decodeStepLiteRT, accelerator: 1 /* CPU */,
                                   threads: 1)

        // Lane count comes off the artifact, exactly as on Apple: dim 0 of the
        // decoder's embed input, which is its first.
        guard dal_lrt_num_inputs(stepSession) == 4,
              dal_lrt_input_rank(stepSession, 0) >= 1 else {
            throw VozError.invalidModel("decode step is missing its embed input")
        }
        var dims = [Int32](repeating: 0, count: 8)
        dims.withUnsafeMutableBufferPointer {
            dal_lrt_input_dims(stepSession, 0, $0.baseAddress)
        }
        decodeLanes = Int(dims[0])
        guard decodeLanes > 0 else {
            throw VozError.invalidModel("decode step declares no lanes")
        }

        let c = configuration
        let lanes = decodeLanes
        let hidden = c.predLayers * c.predHidden
        var owned: [EngineBuffer<Float>] = []
        func allocate(_ count: Int) -> EngineBuffer<Float> {
            let ptr = UnsafeMutablePointer<Float>.allocate(capacity: count)
            ptr.initialize(repeating: 0, count: count)
            let buffer = EngineBuffer(ptr: ptr, count: count)
            owned.append(buffer)
            return buffer
        }
        rows = allocate(c.hopLength * c.nRows)
        melOut = allocate(c.nMels * c.validFrames)
        keyBias = allocate(c.encFrames)
        padMask = allocate(c.encFrames)
        melMask = allocate(c.validFrames)
        encOut = allocate(c.jointHidden * c.encFrames)
        embed = allocate(lanes * c.predHidden)
        hIn = allocate(lanes * hidden)
        cIn = allocate(lanes * hidden)
        encStep = allocate(lanes * c.jointHidden * c.decodeWidth)
        logitsOut = allocate(lanes * (c.vocabSize + 1 + c.durations.count) * c.decodeWidth)
        hOut = allocate(lanes * hidden)
        cOut = allocate(lanes * hidden)
        self.owned = owned

        padMask.ptr.update(repeating: 1, count: padMask.count)

        // Note the logits layout: this export puts the logit axis last
        // (`[1, 1, 1, vocab+1+durations]`) where the Apple graph puts it on
        // axis 1 with the decode width last. At width 1 the two flatten to the
        // same bytes, which the element-count check quietly relies on; a
        // width > 1 export would need the read in `Pipeline.decode` revisited.
        mel = try Self.graph(melSession, name: VozModel.melLiteRT,
                             inputs: [rows, melMask], outputs: [melOut], logEvery: 1)
        encoder = try Self.graph(encoderSession, name: VozModel.encoderLiteRT,
                                 inputs: [melOut, keyBias, padMask], outputs: [encOut],
                                 logEvery: 1)
        decodeStep = try Self.graph(stepSession, name: VozModel.decodeStepLiteRT,
                                    inputs: [embed, hIn, cIn, encStep],
                                    outputs: [logitsOut, hOut, cOut], logEvery: 64)
    }

    deinit {
        dal_lrt_free(mel.session)
        dal_lrt_free(encoder.session)
        dal_lrt_free(decodeStep.session)
        for buffer in owned { buffer.ptr.deallocate() }
    }

    func runMel() throws { try mel.run() }
    func runEncoder() throws { try encoder.run() }
    func runDecodeStep() throws { try decodeStep.run() }

    func withEmbedding<T>(_ body: (UnsafeBufferPointer<Float>) throws -> T) rethrows -> T {
        try embedding.withUnsafeBufferPointer(body)
    }

    // MARK: - Wiring

    /// Bind a session's declared I/O to this engine's buffers by position,
    /// checking element types and counts once at load so a run can trust them.
    private static func graph(
        _ session: OpaquePointer, name: String,
        inputs: [EngineBuffer<Float>],
        outputs: [EngineBuffer<Float>],
        logEvery: Int
    ) throws -> Graph {
        func elements(rank: Int32, dims: (UnsafeMutablePointer<Int32>) -> Void) -> Int {
            var d = [Int32](repeating: 1, count: max(Int(rank), 1))
            d.withUnsafeMutableBufferPointer { dims($0.baseAddress!) }
            return d.prefix(Int(rank)).reduce(1) { $0 * Int(max($1, 1)) }
        }
        guard dal_lrt_num_inputs(session) == inputs.count,
              dal_lrt_num_outputs(session) == outputs.count else {
            throw VozError.invalidModel(
                "\(name) declares \(dal_lrt_num_inputs(session)) inputs and "
                + "\(dal_lrt_num_outputs(session)) outputs, expected "
                + "\(inputs.count) and \(outputs.count)")
        }
        for (i, buffer) in inputs.enumerated() {
            let index = Int32(i)
            guard dal_lrt_input_element_type(session, index) == 1 /* float32 */ else {
                throw VozError.invalidModel("\(name) input \(i) is not float32")
            }
            let declared = elements(rank: dal_lrt_input_rank(session, index)) {
                dal_lrt_input_dims(session, index, $0)
            }
            guard declared == buffer.count else {
                throw VozError.invalidModel(
                    "\(name) input \(i) holds \(declared) elements, expected \(buffer.count)")
            }
        }
        var reads: [(Int32, EngineBuffer<Float>)] = []
        for (i, buffer) in outputs.enumerated() {
            let index = Int32(i)
            guard dal_lrt_output_element_type(session, index) == 1 /* float32 */ else {
                throw VozError.invalidModel("\(name) output \(i) is not float32")
            }
            let declared = elements(rank: dal_lrt_output_rank(session, index)) {
                dal_lrt_output_dims(session, index, $0)
            }
            guard declared == buffer.count else {
                throw VozError.invalidModel(
                    "\(name) output \(i) holds \(declared) elements, expected \(buffer.count)")
            }
            reads.append((index, buffer))
        }
        return Graph(session: session, inputs: inputs, outputs: reads,
                     name: name, logEvery: logEvery)
    }
}

/// IEEE 754 half to float, by hand rather than through `Float16`: the type is
/// unavailable on Intel Apple hosts and this file also builds on Linux CI, so
/// bit twiddling is the one spelling that works everywhere the file does.
private func floatFromHalf(_ half: UInt16) -> Float {
    let sign = UInt32(half >> 15) & 1
    let exponent = UInt32(half >> 10) & 0x1F
    let mantissa = UInt32(half) & 0x3FF
    var bits: UInt32
    if exponent == 0 {
        if mantissa == 0 {
            bits = sign << 31
        } else {
            // Subnormal half: renormalize into a normal float.
            var e: UInt32 = 127 - 15 + 1
            var m = mantissa
            while m & 0x400 == 0 { m <<= 1; e -= 1 }
            bits = (sign << 31) | (e << 23) | ((m & 0x3FF) << 13)
        }
    } else if exponent == 0x1F {
        bits = (sign << 31) | 0x7F80_0000 | (mantissa << 13)  // inf / nan
    } else {
        bits = (sign << 31) | ((exponent + 127 - 15) << 23) | (mantissa << 13)
    }
    return Float(bitPattern: bits)
}
#endif
