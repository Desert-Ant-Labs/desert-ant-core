package ai.desertant.title

import android.content.Context
import ai.desertant.core.FfiWriter
import ai.desertant.core.LoadedModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

// The pinned Granite byte-level vocabulary has at most 128 bytes per token.
// This cap leaves room for anything that fits the 1,280-token context, even
// when the tokenizer compresses long runs of whitespace into single tokens.
private const val MAX_PASSAGE_UTF16 = 128 * 1_280

internal fun encodePassage(text: String): ByteArray {
    var end = minOf(text.length, MAX_PASSAGE_UTF16)
    if (end < text.length && text[end - 1].isHighSurrogate() && text[end].isLowSurrogate()) {
        end--
    }
    return FfiWriter().string(text.substring(0, end)).done()
}

/** A short title and description written on device. */
data class Card(val title: String, val description: String) {
    val isEmpty: Boolean get() = title.isEmpty() && description.isEmpty()
}

/** Thrown when Title cannot be loaded or run. */
class TitleException(message: String) : Exception(message)

/**
 * Writes cards for passages of text. Reuse one instance to keep the model loaded.
 *
 * @param directory Optional model home containing `litert/title.litertlm`.
 * If the file is absent, the SDK downloads it there. The default is the app cache.
 */
class Titles(context: Context, directory: String? = null) : AutoCloseable {
    private val model = LoadedModel("title", "Title", context, directory, ::TitleException, TitleNative)

    /** Whether the model files are available offline. */
    fun isDownloaded(): Boolean = model.isDownloaded()

    /** Fetch and load the model ahead of the first call to [describe]. */
    suspend fun download() = model.download()

    /** Generate one card. Long passages are shortened to fit the model's context. */
    suspend fun describe(text: String): Card = withContext(Dispatchers.Default) {
        model.run(encodePassage(text), failureMessage = "Title generation failed") { reader ->
            Card(reader.string(), reader.string())
        }
    }

    override fun close() = model.close()
}
