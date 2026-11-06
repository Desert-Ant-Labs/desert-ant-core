package ai.desertant.toxic

import ai.desertant.core.FfiReader
import ai.desertant.core.FfiWriter
import ai.desertant.core.LoadedModel

/** The catalog id, which is how the shared native layer is asked for Toxic. */
private const val MODEL_ID = "toxic"
private const val MODEL_NAME = "Toxic"

/** The eleven heads: what a text does, and who a hateful text targets. */
enum class Label(val id: String, val isTarget: Boolean) {
    /** Incitement to hatred or violence against a group. */
    HATEFUL("HATEFUL", false),
    /** Insulting or degrading language, aimed or not. */
    ABUSIVE("ABUSIVE", false),
    /** A threat of violence. */
    THREAT("THREAT", false),
    RACE("RACE", true),
    RELIGION("RELIGION", true),
    NATIONAL_ETHNIC_ORIGIN("NATIONAL_ETHNIC_ORIGIN", true),
    SEXUAL_ORIENTATION("SEXUAL_ORIENTATION", true),
    GENDER("GENDER", true),
    DISABILITY("DISABILITY", true),
    AGE("AGE", true),
    OTHER("OTHER", true);

    companion object {
        /** The three heads that say what a text does. */
        val CONTENT: List<Label> = entries.filter { !it.isTarget }
        /** The eight heads that say which group a hateful text is about. */
        val TARGETS: List<Label> = entries.filter { it.isTarget }
        internal fun byId(id: String): Label? = entries.firstOrNull { it.id == id }
    }
}

/** Options for one [Toxic.analyze] call. */
data class Options(
    /**
     * Thresholds that replace the model's defaults for the heads named; a head at or above its
     * threshold is flagged. The defaults ship with the model, chosen on validation text.
     */
    val thresholds: Map<Label, Double> = emptyMap(),
)

/** The result of analyzing one text. */
data class Analysis(
    /** Every head's probability in `0..1`. */
    val scores: Map<Label, Double>,
    /** The threshold each head was judged at. */
    val thresholds: Map<Label, Double>,
    /** The heads at or above their thresholds, content and target heads alike. */
    val flagged: Set<Label>,
) {
    /** Whether any content head fired: the text is hateful, abusive or threatening at the thresholds. */
    val isToxic: Boolean get() = Label.CONTENT.any { it in flagged }

    /** The content heads that fired, in [Label.CONTENT] order. */
    val content: List<Label> get() = Label.CONTENT.filter { it in flagged }

    /** The target heads that fired, highest score first. Meaningful when [Label.HATEFUL] fired. */
    val targets: List<Label> get() = Label.TARGETS.filter { it in flagged }.sortedByDescending { scores[it] ?: 0.0 }

    /** One head's probability. */
    fun score(label: Label): Double = scores[label] ?: 0.0
}

/** Thrown when the model cannot be created, loaded, or run. */
class ToxicException(message: String) : Exception(message)

/**
 * On-device hate-speech triage. Mirrors the Swift SDK: create one `Toxic` and
 * reuse it; the model loads lazily on the first [analyze] (or eagerly via
 * [download]).
 *
 * ```kotlin
 * Toxic(context).use { toxic ->
 *     val result = toxic.analyze(comment)
 *     if (result.isToxic) holdForReview(result.content, result.targets)
 * }
 * ```
 *
 * The text goes in as written. A text longer than the model's window is read in
 * overlapping windows, and each head keeps its highest score.
 *
 * @param directory the model's home. Files already there are adopted, otherwise
 *   the model is downloaded into it. Omit to use the app cache.
 */
class Toxic(
    context: android.content.Context,
    directory: String? = null,
) : AutoCloseable {
    private val model = LoadedModel(MODEL_ID, MODEL_NAME, context, directory, ::ToxicException, ToxicNative)

    /** Whether the model is available with no network. */
    fun isDownloaded(): Boolean = model.isDownloaded()

    /** Download the model ahead of time so the first [analyze] is instant. */
    suspend fun download() = model.download()

    /** Score a text for hate, abuse and threats, and for the group it targets. */
    suspend fun analyze(text: String, options: Options = Options()): Analysis {
        require(options.thresholds.values.all { it.isFinite() }) { "thresholds must be finite" }
        // Payloads must match Sources/Toxic/Binding.swift.
        val input = FfiWriter().string(text).done()
        val opts = FfiWriter().int(options.thresholds.size).apply {
            for ((label, threshold) in options.thresholds) string(label.id).double(threshold)
        }.done()
        return model.run(input, opts, failureMessage = "analysis failed", decode = ::decodeAnalysis)
    }

    /** Release the native model. Calling this again is a no-op. */
    @Synchronized override fun close() = model.close()
}

private fun decodeAnalysis(r: FfiReader): Analysis {
    val scores = LinkedHashMap<Label, Double>()
    val thresholds = LinkedHashMap<Label, Double>()
    val flagged = LinkedHashSet<Label>()
    repeat(r.int()) {
        val label = Label.byId(r.string())
        val score = r.double()
        val threshold = r.double()
        val flag = r.int() == 1
        if (label != null) {
            scores[label] = score
            thresholds[label] = threshold
            if (flag) flagged += label
        }
    }
    return Analysis(scores, thresholds, flagged)
}
