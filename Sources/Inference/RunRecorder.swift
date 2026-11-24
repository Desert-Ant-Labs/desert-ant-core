// Which processors a model call actually ran on, for the hosts' per-run
// records (Kotlin's DesertAnt.recentRuns()). Only LiteRT sessions report: on
// Apple platforms Core ML places work itself and says nothing about it.

/// Processors, as LiteRT's `LiteRtHwAccelerators` bits, which is also how they
/// cross to the hosts.
public struct ProcessorSet: OptionSet, Sendable, Hashable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let cpu = ProcessorSet(rawValue: 1)
    public static let gpu = ProcessorSet(rawValue: 2)
    public static let npu = ProcessorSet(rawValue: 4)
    static let known: ProcessorSet = [.cpu, .gpu, .npu]
}

/// Where one compiled graph runs, fixed when it is compiled.
public struct GraphPlacement: Sendable, Equatable {
    /// Why a graph that asked for an accelerator runs on the CPU. The first
    /// three are the shim's `DAL_LRT_FALLBACK_*` codes, and the hosts read the
    /// same numbers.
    public enum Fallback: Int32, Sendable {
        case virtualDevice = 1
        case compileFailed = 2
        case buffersUnavailable = 3
        /// The accelerator's library never loaded, usually because the app
        /// left it out of its APK, and LiteRT compiled for the CPU alone.
        case acceleratorMissing = 4
    }

    /// The model file, plus the signature when the file has several.
    public let graph: String
    public let requested: ProcessorSet
    /// Empty when the runtime could not say where an accelerated compile runs
    /// (off Android, where the shim does not ask).
    public let processors: ProcessorSet
    public let fallback: Fallback?

    public init(graph: String, requested: ProcessorSet, processors: ProcessorSet, fallback: Fallback?) {
        self.graph = graph
        self.requested = requested
        self.processors = processors
        self.fallback = fallback
    }

    /// The processors a compile's raw facts (the shim's `DalLrtCompileInfo`)
    /// amount to. `registered` and `nonCpuFullyAccelerated` are -1 where the
    /// runtime was not asked. Without `registered` an accelerated compile's
    /// placement is unknown (no processors): LiteRT compiles GPU|CPU happily
    /// with no GPU accelerator at all, so the compiled set proves nothing.
    ///
    /// GPU and CPU together means LiteRT left part of the graph on the CPU, or
    /// could not say it left none there.
    public static func resolve(requested: Int32, compiled: Int32, registered: Int32,
                               nonCpuFullyAccelerated: Int32, fallback: Int32)
        -> (processors: ProcessorSet, fallback: Fallback?)
    {
        if fallback != 0 { return (.cpu, Fallback(rawValue: fallback)) }
        let accelerators = ProcessorSet(rawValue: compiled).intersection(.known).subtracting(.cpu)
        if accelerators.isEmpty { return (.cpu, nil) }
        if registered < 0 { return ([], nil) }
        let loaded = accelerators.intersection(ProcessorSet(rawValue: registered))
        if loaded.isEmpty { return (.cpu, .acceleratorMissing) }
        return (nonCpuFullyAccelerated == 1 ? loaded : loaded.union(.cpu), nil)
    }

    /// A model file's name alone, on any platform's separators: the directory
    /// is the user's cache, which a log line has no business carrying. A model
    /// from memory is named by its size, so two of them in one call stay apart.
    static func graphName(modelPath: String, modelBytes: [UInt8]?) -> String {
        if let modelBytes { return "in-memory model (\(modelBytes.count) bytes)" }
        let file = modelPath.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
        return file ?? "model"
    }
}

#if !os(WASI)
/// Collects the placements of the graphs one model call runs, once per graph
/// however many times it runs (Voz's decoder steps hundreds of times a call).
/// Two graphs are one only when everything about them matches: a name can
/// repeat (two files called `model.tflite`), and the one that fell back to the
/// CPU must not hide behind the one that did not.
/// `nativeRun` binds a fresh one around each call as
/// `InferenceContext.runRecorder`.
public final class RunRecorder: @unchecked Sendable {
    private let lock = PlatformMutex()
    private var graphs: [GraphPlacement] = []

    public init() {}

    public func record(_ placement: GraphPlacement) {
        lock.lock()
        defer { lock.unlock() }
        // A handful of graphs per model, so a scan beats a dictionary.
        if !graphs.contains(placement) { graphs.append(placement) }
    }

    /// The graphs recorded so far, in the order they first ran.
    public var recorded: [GraphPlacement] {
        lock.lock()
        defer { lock.unlock() }
        return graphs
    }
}
#endif
