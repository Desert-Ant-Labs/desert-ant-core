#if canImport(CoreML) && canImport(CoreAI)
import CoreAI
import CoreML
import Foundation

/// The Core AI engine: the same three graphs, loaded as `.aimodel` assets and
/// run through `InferenceFunction`.
///
/// `Pipeline` is untouched by this. It owns the windowing, the lane-batched
/// decode and the splice, reads and writes `PipelineBuffers` by pointer, and
/// asks for a model call between them; what a runtime brings is how a call is
/// made. So the two engines are a fair comparison by construction - same
/// geometry, same buffers, same decode loop - and the only thing that differs
/// is the runtime underneath.
///
/// Where Core ML takes `MLMultiArray`s bound once into feature providers and
/// writes results back through `outputBackings`, Core AI takes `NDArray`s and
/// writes back through `outputViews`. Both are allocate-nothing, copy-nothing
/// paths, and this one only is because `PipelineBuffers` was told to allocate
/// `NDArray`s: binding is what makes a dispatch a dispatch, and a buffer the
/// engine cannot bind is a memcpy per tensor per call instead.
@available(macOS 27.0, iOS 27.0, *)
final class CoreAIEngine: Engine, @unchecked Sendable {
    let decodeLanes: Int

    /// The decode step is on the CPU by default and the encoder on the Neural
    /// Engine, so they overlap - on a phone too. Measured on an iPhone 16 Pro
    /// over a 10-minute clip: 502-532x realtime overlapped against 391-442x
    /// taking turns.
    var decodeRunsBesideEncoder: Bool { Self.decodeComputeUnit != .neuralEngine }

    /// Core AI dispatches a function's work as one program, and on a
    /// single-engine part a window already fills the engine, so overlapping
    /// buys nothing. `VOZ_COREAI_ENCODE_DEPTH` pins it for an Ultra part.
    var encodeDepth: Int { Self.encodeDepthForLoad }

    static let encodeDepthForLoad =
        Int(ProcessInfo.processInfo.environment["VOZ_COREAI_ENCODE_DEPTH"] ?? "") ?? 1

    private let mel: InferenceFunction
    private let encoder: InferenceFunction
    private let step: InferenceFunction
    private let buffers: PipelineBuffers

    /// The decode step at fewer lanes, with buffers of its own, smallest first.
    ///
    /// At the end of a transcription the encoder is done and the Neural Engine
    /// idles while the CPU finishes the last windows, with most of the lanes
    /// empty - measured on an M5, 123 ms of a 915 ms 10-minute clip, 64 steps.
    /// A step's cost is close to linear in lanes (1.85 ms at 16, 0.67 at 4,
    /// 0.37 at 1), so the lanes still running are gathered into the smallest
    /// step that holds them, and the results scattered back.
    private struct Narrow {
        let lanes: Int
        let function: InferenceFunction
        let embed, hIn, cIn, encStep, logits, hOut, cOut: Buffer
    }
    private let narrow: [Narrow]

    /// Where the time goes, when `VOZ_COREAI_PROFILE` asks.
    ///
    /// Off by default and read only at teardown, because the point of these
    /// engines is that a dispatch is a dispatch: a timer on the hot path would
    /// be measuring itself. A relaxed atomic add per call is cheap enough to
    /// leave in, and knowing the encode/decode split is what decides which half
    /// is worth working on.
    final class Profile: @unchecked Sendable {
        let lock = NSLock()
        var melNanoseconds = 0, encodeNanoseconds = 0, decodeNanoseconds = 0
        var melCalls = 0, encodeCalls = 0, decodeCalls = 0
        func add(mel: Int = 0, encode: Int = 0, decode: Int = 0) {
            lock.lock()
            defer { lock.unlock() }
            if mel > 0 { melNanoseconds += mel; melCalls += 1 }
            if encode > 0 { encodeNanoseconds += encode; encodeCalls += 1 }
            if decode > 0 { decodeNanoseconds += decode; decodeCalls += 1 }
        }
        func report() {
            func line(_ name: String, _ nanoseconds: Int, _ calls: Int) -> String {
                String(format: "  %-8s %8.3f s over %6d calls (%7.3f ms each)",
                       (name as NSString).utf8String!, Double(nanoseconds) / 1e9, calls,
                       calls > 0 ? Double(nanoseconds) / Double(calls) / 1e6 : 0)
            }
            print("VOZ_COREAI_PROFILE")
            print(line("mel", melNanoseconds, melCalls))
            print(line("encoder", encodeNanoseconds, encodeCalls))
            print(line("decode", decodeNanoseconds, decodeCalls))
        }
    }
    static let profiling = ProcessInfo.processInfo.environment["VOZ_COREAI_PROFILE"] != nil
    let profile = Profile()

    deinit { if Self.profiling { profile.report() } }

    /// A timeline of every call, when `VOZ_COREAI_TRACE` names a file: one
    /// line per call, `kind start_ns end_ns`, for finding where the engine
    /// sits idle. Diagnostic only; off costs one branch per call.
    static let traceHandle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["VOZ_COREAI_TRACE"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    static let traceLock = NSLock()
    static func trace(_ kind: String, _ start: UInt64) {
        guard let handle = traceHandle else { return }
        let line = "\(kind) \(start) \(DispatchTime.now().uptimeNanoseconds)\n"
        traceLock.lock(); handle.write(Data(line.utf8)); traceLock.unlock()
    }

    /// Names, kept here rather than spelled at each use so a rename is one edit.
    enum Asset {
        static let mel = "mel.aimodel"
        static let encoder = "encoder.aimodel"
        static let decodeStep = "decoder.aimodel"
        /// One asset holding all three, as the functions `mel`, `encoder` and
        /// `decoder`.
        static let combined = "voz.aimodel"
    }

    /// Whether a directory holds a Core AI bundle rather than a Core ML one.
    static func isPresent(in directory: URL) -> Bool {
        [Asset.encoder, Asset.combined].contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    /// The three functions, from whichever layout the bundle has.
    ///
    /// A combined `voz.aimodel` is specialized once for the Neural Engine, which
    /// gives the mel and the encoder. Specialization options apply to a whole
    /// asset - there is no per-function placement - so a decode step that
    /// belongs elsewhere comes from a second specialization of the same file.
    /// That costs a second cache entry the size of the model (450 MB, ~2 s to
    /// build on an M5), which is the price of one file to ship.
    private static func functions(in directory: URL, decodeOnly: Bool = false)
        async throws -> (mel: InferenceFunction?, encoder: InferenceFunction?,
                         step: InferenceFunction, tail: [InferenceFunction]) {
        do {
            return try await loadFunctions(in: directory, decodeOnly: decodeOnly)
        } catch {
            // A cached specialization can stop loading: measured on an M5, one
            // bundle's cached Neural Engine program was refused by `aned` on
            // every load after the first ("Model load failed ...
            // isPreCompiledModel=1") while a fresh specialization of the same
            // file ran. So a failed load drops this bundle's cache entries and
            // specializes once more before it is an error.
            for name in [Asset.combined, Asset.mel, Asset.encoder, Asset.decodeStep] {
                let url = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                for unit in [ComputeUnitKind.neuralEngine, decodeComputeUnit] {
                    try? AIModelCache.default.deleteEntry(
                        for: url, options: SpecializationOptions(preferredComputeUnitKind: unit))
                }
            }
            return try await loadFunctions(in: directory, decodeOnly: decodeOnly)
        }
    }

    private static func loadFunctions(in directory: URL, decodeOnly: Bool)
        async throws -> (mel: InferenceFunction?, encoder: InferenceFunction?,
                         step: InferenceFunction, tail: [InferenceFunction]) {
        func named(_ model: AIModel, _ name: String) throws -> InferenceFunction {
            guard let function = try model.loadFunction(named: name) else {
                throw VozError.invalidModel("missing function \(name)")
            }
            return function
        }
        let combined = directory.appendingPathComponent(Asset.combined)
        if FileManager.default.fileExists(atPath: combined.path) {
            let engine = decodeOnly && decodeComputeUnit != .neuralEngine
                ? nil : try await load(combined, on: .neuralEngine)
            let decoding = decodeComputeUnit == .neuralEngine
                ? engine! : try await load(combined, on: decodeComputeUnit)
            // The decode step at fewer lanes, where the export included them.
            let tail = try [1, 2, 4, 8, 16, 32].compactMap {
                try decoding.loadFunction(named: "decoder_\($0)")
            }
            return (try engine.map { try named($0, "mel") },
                    try engine.map { try named($0, "encoder") },
                    try named(decoding, "decoder"), tail)
        }
        let step = try named(try await load(directory.appendingPathComponent(Asset.decodeStep),
                                            on: decodeComputeUnit), "main")
        if decodeOnly { return (nil, nil, step, []) }
        return (try named(try await load(directory.appendingPathComponent(Asset.mel),
                                         on: .neuralEngine), "main"),
                try named(try await load(directory.appendingPathComponent(Asset.encoder),
                                         on: .neuralEngine), "main"),
                step, [])
    }

    /// Where the decode step runs: the CPU, on every part.
    ///
    /// The step is small and dispatch-bound. Measured on an iPhone 16 Pro over a
    /// 10-minute clip, Core AI's decode step costs 2.5 ms on the CPU against
    /// 4.6 ms on the Neural Engine (20 ms on the GPU), and with it on the Neural
    /// Engine the app was killed mid-transcription. Core ML's own decode step
    /// is fine on an A-series Neural Engine, which is why `CoreMLEngine` answers
    /// differently. On a Mac the CPU was already the answer.
    ///
    /// This is a placement decision, not a residency one. The encoder - which
    /// is the model - is on the Neural Engine either way.
    /// `VOZ_COREAI_DECODE_UNIT` pins it, so the choice can be re-measured on a
    /// part this was not measured on rather than assumed.
    static var decodeComputeUnit: ComputeUnitKind {
        switch ProcessInfo.processInfo.environment["VOZ_COREAI_DECODE_UNIT"] {
        case "cpu": return .cpu
        case "ane": return .neuralEngine
        case "gpu": return .gpu
        default: return .cpu
        }
    }

    /// Lanes the decode step declares, needed before the buffers exist.
    ///
    /// Read from the asset rather than from `meta.json`: the two can disagree,
    /// and the one that decides the buffer geometry is the graph.
    static func declaredLanes(directory: URL) async throws -> Int {
        try lanes(of: try await functions(in: directory, decodeOnly: true).step)
    }

    private static func lanes(of function: InferenceFunction) throws -> Int {
        guard case .ndArray(let descriptor)? = function.descriptor.inputDescriptor(of: "embed"),
              let lanes = descriptor.shape.first, lanes > 0
        else { throw VozError.invalidModel("decode step is missing its embed input") }
        return lanes
    }

    private static func load(_ url: URL, on unit: ComputeUnitKind) async throws -> AIModel {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VozError.invalidModel("missing \(url.lastPathComponent)")
        }
        // The engine is asked for by name. Core AI's default lets it choose,
        // and on this graph it chooses the GPU: same answer, different
        // hardware, and none of the energy argument for being on device.
        return try await AIModel(contentsOf: url,
                                 options: SpecializationOptions(preferredComputeUnitKind: unit))
    }

    init(directory: URL, buffers: PipelineBuffers) async throws {
        let loaded = try await Self.functions(in: directory)
        mel = loaded.mel!
        encoder = loaded.encoder!
        step = loaded.step
        decodeLanes = try Self.lanes(of: step)
        self.buffers = buffers
        let full = decodeLanes
        narrow = try loaded.tail.compactMap { function in
            let lanes = try Self.lanes(of: function)
            guard lanes < full else { return nil }
            func make(_ like: Buffer) throws -> Buffer {
                try Buffer([lanes] + like.shape.dropFirst(), storage: .coreAI)
            }
            return Narrow(lanes: lanes, function: function,
                          embed: try make(buffers.embed), hIn: try make(buffers.hIn),
                          cIn: try make(buffers.cIn), encStep: try make(buffers.encStep),
                          logits: try make(buffers.logitsOut), hOut: try make(buffers.hOut),
                          cOut: try make(buffers.cOut))
        }.sorted { $0.lanes < $1.lanes }
    }

    // MARK: - Dispatch

    /// One call, with its outputs written into the pipeline's own arrays.
    ///
    /// The `inout` is what makes the binding legal: `MutableViews` borrows what
    /// is inserted into it, and only an `inout` parameter's access scope reaches
    /// across the `await` on `run`.
    private static func run(_ function: InferenceFunction, _ inputs: [String: NDArray],
                            into output: inout NDArray, named name: String) async throws {
        var views = InferenceFunction.MutableViews()
        views.insert(&output, for: name)
        _ = try await function.run(inputs: inputs, outputViews: consume views)
    }

    private static func run(_ function: InferenceFunction, _ inputs: [String: NDArray],
                            into first: inout NDArray, named firstName: String,
                            _ second: inout NDArray, named secondName: String,
                            _ third: inout NDArray, named thirdName: String) async throws {
        var views = InferenceFunction.MutableViews()
        views.insert(&first, for: firstName)
        views.insert(&second, for: secondName)
        views.insert(&third, for: thirdName)
        _ = try await function.run(inputs: inputs, outputViews: consume views)
    }

    func encode(slot index: Int, buffers: PipelineBuffers,
                isolation: isolated (any Actor)?) async throws {
        let slot = buffers.slots[index]
        var start = Self.profiling ? DispatchTime.now().uptimeNanoseconds : 0
        let t0 = DispatchTime.now().uptimeNanoseconds
        try await Self.run(mel, ["audio_rows": slot.rows.ndBox.array,
                                 "mel_mask": slot.melMask.ndBox.array],
                           into: &slot.melOut.ndBox.array, named: "mel")
        Self.trace("mel", t0)
        let t1 = DispatchTime.now().uptimeNanoseconds
        if Self.profiling {
            let now = DispatchTime.now().uptimeNanoseconds
            profile.add(mel: Int(now - start))
            start = now
        }
        try await Self.run(encoder, ["mel": slot.melOut.ndBox.array,
                                     "key_bias": slot.keyBias.ndBox.array,
                                     "pad_mask": buffers.padMask.ndBox.array],
                           into: &slot.encOut.ndBox.array, named: "enc_proj")
        Self.trace("enc", t1)
        if Self.profiling {
            profile.add(encode: Int(DispatchTime.now().uptimeNanoseconds - start))
        }
    }

    func runDecodeStep(embed: Buffer, hIn: Buffer, cIn: Buffer, encStep: Buffer,
                       logits: Buffer, hOut: Buffer, cOut: Buffer, activeLanes: [Int],
                       isolation: isolated (any Actor)?) async throws {
        let start = Self.profiling ? DispatchTime.now().uptimeNanoseconds : 0
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { if Self.traceHandle != nil { Self.trace("dec\(activeLanes.count)", t0) } }
        if let small = narrow.first(where: { $0.lanes >= activeLanes.count }) {
            func gather(_ from: Buffer, _ into: Buffer) {
                let per = from.count / decodeLanes
                for (i, lane) in activeLanes.enumerated() {
                    (into.ptr + i * per).update(from: from.ptr + lane * per, count: per)
                }
            }
            func scatter(_ from: Buffer, _ into: Buffer) {
                let per = into.count / decodeLanes
                for (i, lane) in activeLanes.enumerated() {
                    (into.ptr + lane * per).update(from: from.ptr + i * per, count: per)
                }
            }
            gather(embed, small.embed); gather(hIn, small.hIn)
            gather(cIn, small.cIn); gather(encStep, small.encStep)
            try await Self.run(small.function,
                               ["embed": small.embed.ndBox.array, "h_in": small.hIn.ndBox.array,
                                "c_in": small.cIn.ndBox.array,
                                "enc_step": small.encStep.ndBox.array],
                               into: &small.logits.ndBox.array, named: "logits",
                               &small.hOut.ndBox.array, named: "h_out",
                               &small.cOut.ndBox.array, named: "c_out")
            scatter(small.logits, logits); scatter(small.hOut, hOut); scatter(small.cOut, cOut)
        } else {
            try await Self.run(step, ["embed": embed.ndBox.array, "h_in": hIn.ndBox.array,
                                      "c_in": cIn.ndBox.array, "enc_step": encStep.ndBox.array],
                               into: &logits.ndBox.array, named: "logits",
                               &hOut.ndBox.array, named: "h_out",
                               &cOut.ndBox.array, named: "c_out")
        }
        if Self.profiling {
            profile.add(decode: Int(DispatchTime.now().uptimeNanoseconds - start))
        }
    }
}
#endif
