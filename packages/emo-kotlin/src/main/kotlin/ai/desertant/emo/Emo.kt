package ai.desertant.emo

import ai.desertant.core.FfiReader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

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
 */
class Emo private constructor(private val handle: Long) : AutoCloseable {
    /**
     * A suggester using the bundled model by default. When [directory] is
     * supplied, that directory is treated as the model's home instead (adopt
     * files there, else download into it). Construction is cheap; the model
     * loads on the first [suggestions] (or eagerly via [download]).
     */
    constructor(context: android.content.Context, directory: String? = null)
        : this(if (directory == null) bundledHandleOrNull() ?: createHandle(context.cacheDir.absolutePath, null)
               else createHandle(context.cacheDir.absolutePath, directory))

    companion object {
        /**
         * A suggester using the bundled model (no network). The main Emo AAR
         * depends on the resources artifact by default because the model is
         * small; this remains useful for explicit offline construction.
         */
        fun bundled(): Emo {
            val handle = bundledHandleOrNull() ?: throw EmoException(
                "bundled model unavailable; make sure `ai.desertant:emo-tflite-resources` is present")
            return Emo(handle)
        }

        private fun bundledHandleOrNull(): Long? {
            EmoNative.ensureLoaded()
            val meta = resourceOrNull("emo_meta.json") ?: return null
            val tokenizer = resourceOrNull("emo_tokenizer.bin") ?: return null
            val model = resourceOrNull("emo.tflite") ?: return null
            val handle = EmoNative.createBundled(meta, tokenizer, model)
            return handle.takeIf { it != 0L }
        }

        private fun createHandle(cacheRoot: String, directory: String?): Long {
            EmoNative.ensureLoaded()
            val handle = EmoNative.create(
                cacheRoot.toByteArray(Charsets.UTF_8), directory?.toByteArray(Charsets.UTF_8))
            if (handle == 0L) throw EmoException("failed to create Emo")
            return handle
        }

        private fun resourceOrNull(name: String): ByteArray? =
            Emo::class.java.getResourceAsStream("/$name")?.use { it.readBytes() }
    }

    /** Whether the model is available for this suggester with no network. */
    fun isDownloaded(): Boolean = EmoNative.isDownloaded(handle) != 0

    /**
     * Download the model ahead of time so the first [suggestions] is instant. A
     * no-op once available (see [isDownloaded]). Suspends on a background
     * dispatcher.
     */
    suspend fun download(): Unit = withContext(Dispatchers.IO) {
        if (EmoNative.download(handle) != 0) throw EmoException("model download failed")
    }

    /**
     * Suggest emojis for [text], most likely first. Returns up to [limit]
     * suggestions; empty or blank input returns an empty list. Loads the model
     * lazily on first call.
     */
    suspend fun suggestions(
        text: String, limit: Int = 3, skinTone: EmojiSkinTone = EmojiSkinTone.DEFAULT,
    ): List<EmoSuggestion> = withContext(Dispatchers.Default) {
        if (text.isBlank()) return@withContext emptyList()
        val bytes = EmoNative.run(handle, text.toByteArray(Charsets.UTF_8), limit, skinTone.nativeValue)
            ?: throw EmoException("suggestion failed")
        val r = FfiReader(bytes)
        List(r.int()) { EmoSuggestion(r.string(), r.double()) }
    }

    /** Release the native model. The suggester is unusable afterwards. */
    override fun close() = EmoNative.destroy(handle)
}
