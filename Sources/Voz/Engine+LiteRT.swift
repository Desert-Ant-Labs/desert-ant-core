#if canImport(CLiteRt)
import CLiteRt
import Foundation

/// The LiteRT engine (Android/Linux): three `.tflite` graphs behind the
/// `CLiteRt` shim, driven with the pipeline's preallocated buffers.
///
/// Drives the shim directly rather than going through `InferenceSession`, for
/// the same reason the Core ML engine drives Core ML directly: the decode loop
/// dispatches hundreds of times per minute of audio, and a marshalling API
/// that copies every tensor per call is exactly the cost the preallocated
/// buffers exist to avoid. Inputs are pinned host buffers the pipeline writes
/// in place; outputs are copied out of the shim's fixed buffers once per run.
///
/// Geometry comes from `meta.litert.json`, not the shared `meta.json`: the two
/// exports genuinely differ (this one decodes one lane at width 1, float32
/// I/O), and the Apple file would size every decode buffer wrong. `Element` is
/// `Float` off Apple platforms (Buffers.swift), which is what the graphs
/// declare, so nothing converts at the boundary.
///
/// Tensors bind by position, not name: the export names every signature tensor
/// `args_N`/`output_N`, so names carry nothing to check. The order is the same
/// as the Apple providers' (mel: audio rows, mel mask; encoder: mel, key bias,
/// pad mask; decode: embed, h, c, enc step -> logits, h, c), and every binding
/// is checked against the declared shape at load, so a reordered export fails
/// loudly with the sizes rather than feeding the wrong tensor.
final class LiteRTEngine: Engine {
    let decodeLanes: Int
    /// One: the shipping export has a batch-1 encoder, and unlike the wasm
    /// host there is no per-call boundary cost for batching to amortise.
    let encodeBatch = 1
    /// Raw logits: the host's argmax over the copied-out buffer is a memory
    /// walk, and the export predates the reduced form.
    let reducesInGraph = false
    /// One encode in flight, so one slot of frontend buffers. The shim runs
    /// synchronously and the GPU feeds one queue; overlap is unmeasured here,
    /// so raise it after a measurement, not before.
    let encodeDepth = 1
    /// The decode step runs on the CPU while the encoder sits on the GPU, so
    /// the two could overlap; leave it off until that overlap is measured on
    /// device rather than assumed.
    let decodeRunsBesideEncoder = false

    private let mel: Graph
    private let encoder: Graph
    private let decodeStep: Graph

    /// One compiled graph: the shim session plus the pipeline buffer for each
    /// declared input (in the graph's input order) and output it reads back.
    ///
    /// A class for the timing counters alone: where a transcription spends its
    /// time is invisible from Kotlin, and "1x realtime" with no breakdown is
    /// undebuggable. Every run is counted and summarised to the platform log,
    /// cheaply enough to leave on: one clock read per dispatch and one log
    /// line per 15 s window (or 64 decode steps).
    private final class Graph {
        let session: OpaquePointer
        let inputs: [Buffer]
        let outputs: [(index: Int32, into: Buffer)]
        let name: String
        /// Log a summary every this many runs: 1 for the per-window graphs,
        /// larger for the decode step so it does not flood.
        let logEvery: Int
        private var runs = 0
        private var totalSeconds = 0.0
        private var sinceLog = 0.0

        init(session: OpaquePointer, inputs: [Buffer],
             outputs: [(index: Int32, into: Buffer)], name: String, logEvery: Int) {
            self.session = session
            self.inputs = inputs
            self.outputs = outputs
            self.name = name
            self.logEvery = logEvery
        }

        deinit { dal_lrt_free(session) }

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
            let lengths: [Int] = inputs.map { $0.count * MemoryLayout<Element>.stride }
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
                      bytes == buffer.count * MemoryLayout<Element>.stride else {
                    throw VozError.invalidModel(
                        "output \(index) returned \(bytes) bytes, expected "
                        + "\(buffer.count * MemoryLayout<Element>.stride)")
                }
                buffer.ptr.update(from: data.assumingMemoryBound(to: Element.self),
                                  count: buffer.count)
            }
        }
    }

    /// Open the three graphs, size the buffers off the artifact, and bind them.
    ///
    /// A factory rather than an init because the lane count lives in the
    /// decoder's declared shapes, and the buffers cannot be allocated until it
    /// is known - the same two-step the Core ML path does with
    /// `declaredLanes`, collapsed into one open per session.
    static func load(directory: URL, configuration c: Configuration) throws
        -> (engine: LiteRTEngine, buffers: PipelineBuffers)
    {
        func open(_ name: String, accelerator: Int32, threads: Int32 = 0,
                  gpuPrecision: Int32 = 0) throws -> OpaquePointer {
            let path = directory.appendingPathComponent(name).path
            var errbuf = [CChar](repeating: 0, count: 256)
            let handle = errbuf.withUnsafeMutableBufferPointer { err in
                path.withCString {
                    dal_lrt_create($0, nil, 0, accelerator, threads, gpuPrecision,
                                   err.baseAddress, Int32(err.count))
                }
            }
            guard let handle else {
                throw VozError.invalidModel("\(name): \(String(cString: errbuf))")
            }
            return handle
        }

        // The mel frontend must not run in reduced precision (its statistics
        // are the fragile half of the model), and the encoder collapses in
        // plain fp16 (373 words to 163 on the benchmark take: a conformer is
        // long dot products end to end), so both ask for fp32. On the GPU
        // that measures the same 0.39s per window as fp16-with-fp32-accum on
        // a Tensor G6, so there is nothing to trade. CPU fallback is
        // automatic when no GPU (or no OpenCL) is present.
        let melSession = try open(VozModel.melLiteRT, accelerator: 3 /* GPU|CPU */,
                                  gpuPrecision: 2 /* fp32 */)
        let encoderSession = try open(VozModel.encoderLiteRT, accelerator: 3 /* GPU|CPU */,
                                      gpuPrecision: 2 /* fp32 */)
        // One thread as well as CPU-only: a decode step is a few hundred
        // kiloflops, and a thread pool spends more per step waking and
        // joining workers than the work costs (measured 60 ms against 1.5 ms
        // per step). It is also the natural NPU target - see Tools/npu/ for
        // why that door is not open yet.
        let stepSession = try open(VozModel.decodeStepLiteRT, accelerator: 1 /* CPU */,
                                   threads: 1)

        // Lane count comes off the artifact, exactly as on Apple: dim 0 of
        // the decoder's embed input, which is its first.
        guard dal_lrt_num_inputs(stepSession) == 4,
              dal_lrt_input_rank(stepSession, 0) >= 1 else {
            throw VozError.invalidModel("decode step is missing its embed input")
        }
        var dims = [Int32](repeating: 0, count: 8)
        dims.withUnsafeMutableBufferPointer {
            dal_lrt_input_dims(stepSession, 0, $0.baseAddress)
        }
        let lanes = Int(dims[0])
        guard lanes > 0 else {
            throw VozError.invalidModel("decode step declares no lanes")
        }

        let buffers = try PipelineBuffers(configuration: c, lanes: lanes)
        let engine = try LiteRTEngine(
            lanes: lanes, buffers: buffers,
            melSession: melSession, encoderSession: encoderSession,
            stepSession: stepSession)
        return (engine, buffers)
    }

    private init(lanes: Int, buffers: PipelineBuffers,
                 melSession: OpaquePointer, encoderSession: OpaquePointer,
                 stepSession: OpaquePointer) throws {
        decodeLanes = lanes
        // Note the logits layout: this export puts the logit axis last
        // (`[1, 1, 1, vocab+1+durations]`) where the Apple graph puts it on
        // axis 1 with the decode width last. At width 1 the two flatten to the
        // same bytes, which the element-count check quietly relies on; a
        // width > 1 export would need the read in `Pipeline` revisited.
        //
        // The frontend binds slot 0 alone: encodeDepth is 1, so the pipeline
        // never stages a second slot.
        let slot = buffers.slots[0]
        mel = try Self.graph(melSession, name: VozModel.melLiteRT,
                             inputs: [slot.rows, slot.melMask],
                             outputs: [slot.melOut], logEvery: 1)
        encoder = try Self.graph(encoderSession, name: VozModel.encoderLiteRT,
                                 inputs: [slot.melOut, slot.keyBias, buffers.padMask],
                                 outputs: [slot.encOut], logEvery: 1)
        decodeStep = try Self.graph(stepSession, name: VozModel.decodeStepLiteRT,
                                    inputs: [buffers.embed, buffers.hIn, buffers.cIn,
                                             buffers.encStep],
                                    outputs: [buffers.logitsOut, buffers.hOut, buffers.cOut],
                                    logEvery: 64)
    }

    /// Bind a session's declared I/O to the pipeline's buffers by position,
    /// checking element types and counts once at load so a run can trust them.
    private static func graph(
        _ session: OpaquePointer, name: String,
        inputs: [Buffer], outputs: [Buffer], logEvery: Int
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
        var reads: [(Int32, Buffer)] = []
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

    // The buffers are already bound into the graphs, so these take their
    // arguments only to satisfy the protocol. Sync bodies: the engine is
    // async because the wasm host is; nothing here suspends.

    func encode(slot index: Int, lanes: Int, buffers: PipelineBuffers,
                isolation: isolated (any Actor)?) async throws {
        // The graphs were bound to slot 0 at init; encodeDepth is 1, so that
        // is the only slot the pipeline ever stages.
        try mel.run()
        try encoder.run()
    }

    func runDecodeStep(embed: Buffer, hIn: Buffer, cIn: Buffer, encStep: Buffer,
                       logits: Buffer, tok: inout [Int32], dur: inout [Int32],
                       hOut: Buffer, cOut: Buffer, activeLanes: [Int],
                       isolation: isolated (any Actor)?) async throws {
        try decodeStep.run()
    }
}
#endif
