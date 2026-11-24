package ai.desertant.core

/** A processor a model's graphs can run on. */
enum class Processor(internal val bit: Int) {
    CPU(1),
    GPU(2),

    /** Reserved: no model asks for an NPU on Android yet. */
    NPU(4),
    ;

    internal companion object {
        fun setOf(bits: Int): Set<Processor> = entries.filterTo(mutableSetOf()) { bits and it.bit != 0 }
    }
}

/** Why a graph that asked for an accelerator runs on the CPU instead. */
enum class FallbackReason(internal val code: Int) {
    /** An emulator or other virtual device, where the SDK never uses the GPU. */
    EMULATOR(1),

    /** The device's driver rejected the graph when it was compiled for the GPU. */
    COMPILE_FAILED(2),

    /** The GPU compile succeeded, but its input and output buffers could not be mapped. */
    BUFFERS_UNAVAILABLE(3),

    /**
     * The GPU accelerator library never loaded, usually because the app's APK
     * leaves out `libLiteRtClGlAccelerator.so`. [DesertAnt.checkHealth] reports it.
     */
    ACCELERATOR_MISSING(4),
    ;

    internal companion object {
        fun of(code: Int): FallbackReason? = entries.firstOrNull { it.code == code }
    }
}

/**
 * One graph of a model call: the file (and signature, when the file has
 * several) and where it ran. Where a graph runs is decided when it is
 * compiled, so it is the same on every run of a loaded model.
 *
 * @property processors more than one means LiteRT split the graph: what the
 *   accelerator cannot run stays on the CPU. Empty when the runtime could not
 *   say where an accelerated graph runs.
 * @property requested what the model asked for. A model that asks for the CPU
 *   alone does so on purpose, for a graph the GPU runs slower.
 * @property fallbackReason why it runs on the CPU although it asked for more,
 *   or null when it got what it asked for.
 */
data class GraphRun(
    val graph: String,
    val processors: Set<Processor>,
    val requested: Set<Processor>,
    val fallbackReason: FallbackReason?,
)

/**
 * One model call, as [DesertAnt.recentRuns] keeps it.
 *
 * @property modelId the catalog id (`"eye"`, `"voz"`, ...).
 * @property startedAtMillis wall-clock start, from [System.currentTimeMillis].
 * @property durationMillis wall time of the native call, model download
 *   included when the call triggered one.
 * @property succeeded false when the call failed; the graphs that ran before
 *   it failed are still listed.
 * @property graphs each graph the call ran, once, in the order it first ran.
 *   Empty for a model that runs no LiteRT graph.
 */
data class RunRecord(
    val modelId: String,
    val startedAtMillis: Long,
    val durationMillis: Double,
    val succeeded: Boolean,
    val graphs: List<GraphRun>,
) {
    /** Every processor any graph of the call ran on. More than one is a mix. */
    val processors: Set<Processor> get() = graphs.flatMapTo(mutableSetOf()) { it.processors }
}

/** The last [CAPACITY] model calls, in memory only. */
internal object RunHistory {
    const val CAPACITY = 256

    private val runs = ArrayDeque<RunRecord>()

    @Synchronized
    fun add(run: RunRecord) {
        if (runs.size == CAPACITY) runs.removeFirst()
        runs.addLast(run)
    }

    @Synchronized
    fun snapshot(modelId: String?): List<RunRecord> =
        if (modelId == null) runs.toList() else runs.filter { it.modelId == modelId }

    @Synchronized
    fun clear() = runs.clear()

    /**
     * The record the native core sends after each call (Sources/NativeBindings'
     * `runRecord`): a format version, success, wall time in milliseconds, then
     * each graph's name, requested and used processor bits, and fallback code.
     * Null for a version this core cannot read.
     */
    fun decode(modelId: String, payload: ByteArray, receivedAtMillis: Long): RunRecord? {
        val reader = FfiReader(payload)
        if (reader.int() != 1) return null
        val succeeded = reader.int() != 0
        val durationMillis = reader.double()
        val graphs = List(reader.int()) {
            val graph = reader.string()
            val requested = Processor.setOf(reader.int())
            val processors = Processor.setOf(reader.int())
            GraphRun(graph, processors, requested, FallbackReason.of(reader.int()))
        }
        return RunRecord(
            modelId = modelId,
            startedAtMillis = receivedAtMillis - durationMillis.toLong(),
            durationMillis = durationMillis,
            succeeded = succeeded,
            graphs = graphs,
        )
    }
}
