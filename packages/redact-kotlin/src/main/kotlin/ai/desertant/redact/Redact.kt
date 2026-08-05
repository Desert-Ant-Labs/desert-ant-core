package ai.desertant.redact

import ai.desertant.core.FfiWriter
import ai.desertant.core.LoadedModel

/** The catalog id, which is how the shared native layer is asked for Redact. */
private const val MODEL_ID = "redact"
private const val MODEL_NAME = "Redact"

/** A single detected entity and the placeholder that stands in for it. */
data class RedactionItem(
    /** PII category, e.g. `"EMAIL"`. */
    val label: String,
    /** The original (sensitive) text that was matched. */
    val original: String,
    /** The unique, restorable placeholder, e.g. `"[EMAIL_1]"`. */
    val placeholder: String,
    /** Confidence in `0.0..1.0` (deterministic recognizers report `1.0`). */
    val confidence: Double,
    /** Start offset of [original] in the source text (UTF-16). */
    val start: Int,
    /** End offset (exclusive). */
    val end: Int,
)

/**
 * A redaction: text with unique placeholders, the detections, and the mapping
 * needed to restore the originals after out-of-band processing (e.g. an LLM).
 */
data class Redaction(
    /** The input with each entity replaced by its `[LABEL_N]` placeholder. */
    val redactedText: String,
    /** Every detected entity, in document order. */
    val items: List<RedactionItem>,
) {
    /** Fill the originals back into [processed] by substituting each placeholder. */
    fun restore(processed: String): String {
        var out = processed
        for (item in items) out = out.replace(item.placeholder, item.original)
        return out
    }
}

/** Options controlling detection and redaction. */
data class Options(
    /** Minimum confidence for neural detections. Structured recognizers always
     * apply. Default `0.6`. */
    val minimumConfidence: Double = 0.6,
    /** If set, only these categories are detected/redacted; otherwise all are. */
    val labels: Set<String>? = null,
)

/** Thrown when the model cannot be created, loaded, or run. */
class RedactException(message: String) : Exception(message)

/**
 * On-device, multilingual PII redaction. Mirrors the iOS/Swift SDK: create one
 * `Redact` and reuse it; the model loads lazily on the first [redaction] (or
 * eagerly via [download]).
 *
 * ```kotlin
 * val redact = Redact(context)                 // downloads on first use
 * val r = redact.redaction("Email Anna at anna@example.com.")
 * r.redactedText            // "Email [GIVEN_NAME_1] at [EMAIL_1]."
 * redact.close()
 * ```
 *
 * Creating, downloading, running, and releasing the model are the shared
 * `ai.desertant:core` shell ([LoadedModel]); what lives here is Redact's API and
 * its payload schemas.
 *
 * @param directory the model's home. Files already there are adopted (so an app
 *   that ships the model just points at the folder it unpacked it into),
 *   otherwise the model is downloaded into it. Omit to use the app cache.
 */
class Redact(
    context: android.content.Context,
    directory: String? = null,
) : AutoCloseable {
    private val model = LoadedModel(MODEL_ID, MODEL_NAME, context, directory, ::RedactException)

    // The old handle factory lived here. Keep the marker so the generated JVM
    // `Redact.Companion` field remains binary-compatible.
    companion object

    /** Whether the model is available for this redactor with no network. */
    fun isDownloaded(): Boolean = model.isDownloaded()

    /**
     * Download the model ahead of time so the first [redaction] is instant. A
     * no-op once available (see [isDownloaded]). Suspends on a background
     * dispatcher.
     */
    suspend fun download() = model.download()

    /**
     * Detect and redact the PII in [text]. Each entity is replaced by a unique,
     * numbered placeholder (`[EMAIL_1]`, `[GIVEN_NAME_1]`, ...), safe to hand to
     * an LLM and restore afterwards via [Redaction.restore]. Loads the model
     * lazily on first call.
     */
    suspend fun redaction(text: String, options: Options = Options()): Redaction {
        // Options payload: f64 minimumConfidence, then a label count and that
        // many names (empty means every label); result payload: the redacted
        // text, an item count, then per item its strings, confidence, and UTF-16
        // offsets. Must match Sources/ModelCatalog/Redact/Binding.swift.
        val payload = FfiWriter()
            .double(options.minimumConfidence)
            .strings(options.labels?.toList() ?: emptyList())
            .done()
        return model.run(text, payload, failureMessage = "redaction failed") { r ->
            val redactedText = r.string()
            val items = List(r.int()) {
                RedactionItem(
                    label = r.string(),
                    original = r.string(),
                    placeholder = r.string(),
                    confidence = r.double(),
                    start = r.int(),
                    end = r.int(),
                )
            }
            Redaction(redactedText = redactedText, items = items)
        }
    }

    /** Release the native model. The redactor is unusable afterwards; calling
     *  this again is a no-op. */
    @Synchronized override fun close() = model.close()
}
