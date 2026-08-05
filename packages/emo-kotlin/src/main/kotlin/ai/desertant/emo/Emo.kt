package ai.desertant.emo

import ai.desertant.DesertAntNative
import ai.desertant.core.FfiReader
import ai.desertant.core.FfiWriter

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** The catalog id, which is how the shared native layer is asked for Emo. */
private const val MODEL_ID = "emo"
private val MODEL_ID_BYTES = MODEL_ID.toByteArray(Charsets.UTF_8)

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
     * A suggester that downloads the model into the app cache on first use and
     * reuses it offline afterward. When [directory] is supplied, that directory
     * is the model's home instead: files already there are adopted (so an app
     * that ships the model just points at the folder it unpacked it into),
     * otherwise the model is downloaded into it. Construction is cheap; the
     * model loads on the first [suggestions] (or eagerly via [download]).
     */
    constructor(context: android.content.Context, directory: String? = null)
        : this(createHandle(context.cacheDir.absolutePath, directory))

    companion object {
        private fun createHandle(cacheRoot: String, directory: String?): Long {
            DesertAntNative.ensureLoaded()
            val handle = DesertAntNative.create(
                MODEL_ID_BYTES,
                cacheRoot.toByteArray(Charsets.UTF_8),
                directory?.toByteArray(Charsets.UTF_8))
            if (handle == 0L) throw EmoException("failed to create Emo")
            return handle
        }
    }

    /** Whether the model is available for this suggester with no network. */
    fun isDownloaded(): Boolean = DesertAntNative.isDownloaded(handle) != 0

    /**
     * Download the model ahead of time so the first [suggestions] is instant. A
     * no-op once available (see [isDownloaded]). Suspends on a background
     * dispatcher.
     */
    suspend fun download(): Unit = withContext(Dispatchers.IO) {
        if (DesertAntNative.download(handle) != 0) throw EmoException("model download failed")
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
        // Options payload: u32 limit, u32 skinTone. Must match the reader in
        // Sources/ModelCatalog/Emo/Binding.swift.
        val options = FfiWriter().int(limit).int(skinTone.nativeValue).done()
        val bytes = DesertAntNative.run(handle, text.toByteArray(Charsets.UTF_8), options)
            ?: throw EmoException("suggestion failed")
        val r = FfiReader(bytes)
        List(r.int()) { EmoSuggestion(r.string(), r.double()) }
    }

    /** Release the native model. The suggester is unusable afterwards. */
    override fun close() = DesertAntNative.destroy(handle)
}
