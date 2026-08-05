package ai.desertant.emo

import ai.desertant.core.FfiWriter
import ai.desertant.core.LoadedModel

/** The catalog id, which is how the shared native layer is asked for Emo. */
private const val MODEL_ID = "emo"
private const val MODEL_NAME = "Emo"

/** A single emoji suggestion returned by [Emo.suggestions]. */
data class EmoSuggestion(
    /** The suggested emoji. */
    val emoji: String,
    /** The model's normalized confidence for this suggestion, from `0.0` to `1.0`. */
    val confidence: Double,
)

/** Thrown when the model cannot be created, loaded, or run. */
class EmoException(message: String) : Exception(message)

/**
 * On-device multilingual emoji suggestion. Mirrors the iOS/Swift SDK: create one
 * `Emo` and reuse it; the model loads lazily on the first [suggestions] (or
 * eagerly via [download]).
 *
 * ```kotlin
 * val emo = Emo(context)                          // download on demand, cached
 * val suggestions = emo.suggestions("Pay my bills")
 * val toned = emo.suggestions("go for a run", limit = 1, skinTone = EmojiSkinTone.MEDIUM)
 * emo.close()
 * ```
 *
 * Creating, downloading, running, and releasing the model are the shared
 * `ai.desertant:core` shell ([LoadedModel]); what lives here is Emo's API and
 * its payload schemas.
 *
 * @param directory the model's home. Files already there are adopted (so an app
 *   that ships the model just points at the folder it unpacked it into),
 *   otherwise the model is downloaded into it. Omit to use the app cache.
 */
class Emo(
    context: android.content.Context,
    directory: String? = null,
) : AutoCloseable {
    private val model = LoadedModel(MODEL_ID, MODEL_NAME, context, directory, ::EmoException)

    // The old handle factory lived here. Keep the marker so the generated JVM
    // `Emo.Companion` field remains binary-compatible.
    companion object

    /** Whether the model is available for this suggester with no network. */
    fun isDownloaded(): Boolean = model.isDownloaded()

    /**
     * Download the model ahead of time so the first [suggestions] is instant. A
     * no-op once available (see [isDownloaded]). Suspends on a background
     * dispatcher.
     */
    suspend fun download() = model.download()

    /**
     * Suggest emojis for [text], most likely first. Returns up to [limit]
     * suggestions; empty or blank input returns an empty list. Loads the model
     * lazily on first call.
     */
    suspend fun suggestions(
        text: String, limit: Int = 3, skinTone: EmojiSkinTone = EmojiSkinTone.DEFAULT,
    ): List<EmoSuggestion> {
        if (text.isBlank()) return emptyList()
        // Options payload: u32 limit, u32 skinTone; result payload: a count, then
        // per suggestion an emoji string and an f64 confidence. Must match
        // Sources/ModelCatalog/Emo/Binding.swift.
        val options = FfiWriter().int(limit).int(skinTone.nativeValue).done()
        return model.run(text, options, failureMessage = "suggestion failed") { r ->
            List(r.int()) { EmoSuggestion(r.string(), r.double()) }
        }
    }

    /** Release the native model. The suggester is unusable afterwards; calling
     *  this again is a no-op. */
    @Synchronized override fun close() = model.close()
}
