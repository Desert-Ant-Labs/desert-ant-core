package ai.desertant.core

import android.content.Context
import ai.desertant.DesertAntNative
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * A model loaded through the shared native core, behind its opaque handle - the
 * Android counterpart of the Swift SDK's `LoadedModel` and the JS SDK's.
 *
 * Every model SDK used to write this itself: load the libraries, create the
 * handle, check availability, download off the main thread, run and hand back a
 * reader, and release exactly once. Only the exception type differed. It is also
 * where an SDK could go quietly wrong - the handle is a retained pointer, so
 * releasing it twice over-releases the model and using it after release
 * dereferences freed memory, both easy to hit with `use { }` plus a defensive
 * `close()`.
 *
 * So it lives here once, and a model SDK keeps only its public API and its
 * payload schemas:
 *
 * ```kotlin
 * class Emo(context: Context, directory: String? = null) : AutoCloseable {
 *     private val model = LoadedModel(MODEL_ID, "Emo", context, directory, ::EmoException)
 *
 *     suspend fun suggestions(text: String, limit: Int = 3): List<EmoSuggestion> {
 *         return model.run(text, FfiWriter().int(limit).done()) { r ->
 *             List(r.int()) { EmoSuggestion(r.string(), r.double()) }
 *         }
 *     }
 *
 *     override fun close() = model.close()
 * }
 * ```
 *
 * @param modelId the catalog id (`"emo"`, `"redact"`, ...), which is how the
 *   model-agnostic native ABI is asked for this model.
 * @param name the public SDK name, used in its existing creation/closed errors.
 * @param context used only for its cache dir, the base of the managed model
 *   cache.
 * @param directory the model's home. Files already there are adopted (so an app
 *   that ships the model points at the folder it unpacked it into), otherwise
 *   the model is downloaded into it. Null uses the managed cache.
 * @param fail builds the SDK's own exception type, so callers keep catching
 *   `EmoException` / `RedactException` rather than something generic.
 */
class LoadedModel internal constructor(
    modelId: String,
    private val name: String,
    cacheRoot: String,
    directory: String?,
    private val fail: (String) -> Exception,
    private val native: NativeModelApi,
) : AutoCloseable {
    private val handle: Long

    @Volatile private var closed = false

    constructor(
        modelId: String,
        name: String,
        context: Context,
        directory: String? = null,
        fail: (String) -> Exception,
    ) : this(modelId, name, context.cacheDir.absolutePath, directory, fail, JniModelApi)

    init {
        native.ensureLoaded()
        // Construction is cheap: the native side is lazy, so nothing is
        // downloaded or loaded until download() or the first run().
        handle = native.create(
            modelId.toByteArray(Charsets.UTF_8),
            cacheRoot.toByteArray(Charsets.UTF_8),
            directory?.toByteArray(Charsets.UTF_8),
        )
        if (handle == 0L) throw fail("failed to create $name")
    }

    /**
     * Hold the same monitor close() uses until the native operation returns, so
     * another thread cannot destroy the retained pointer between checking
     * `closed` and using it. It also serializes inference on one model handle.
     */
    private inline fun <T> withHandle(operation: (Long) -> T): T = synchronized(this) {
        if (closed) throw fail("this $name is closed")
        operation(handle)
    }

    /** Whether the model is usable with no network. */
    fun isDownloaded(): Boolean = withHandle { native.isDownloaded(it) != 0 }

    /**
     * Fetch and load the model ahead of time so the first [run] is instant. A
     * no-op once available (see [isDownloaded]). Blocking work runs on the IO
     * dispatcher.
     */
    suspend fun download(): Unit = withContext(Dispatchers.IO) {
        if (withHandle { native.download(it) } != 0) throw fail("model download failed")
    }

    /**
     * Run the model over [text] with the model's own [options] payload (null for
     * its defaults), then [decode] the model's result payload. Both inference
     * and decoding run on the default dispatcher.
     */
    suspend fun <Result> run(
        text: String,
        options: ByteArray? = null,
        failureMessage: String = "model run failed",
        decode: (FfiReader) -> Result,
    ): Result = withContext(Dispatchers.Default) {
        val bytes = withHandle {
            native.run(it, text.toByteArray(Charsets.UTF_8), options)
        } ?: throw fail(failureMessage)
        // Decode here too, rather than returning to a possibly-main caller with
        // the model's binary result still to process.
        decode(FfiReader(bytes))
    }

    /**
     * Release the native model. It is unusable afterwards, and calling this again
     * is a no-op.
     */
    @Synchronized override fun close() {
        if (closed) return
        closed = true
        native.destroy(handle)
    }
}

/** The native operations are injectable only so the lifecycle can be tested on
 * the host JVM without loading Android's native libraries. */
internal interface NativeModelApi {
    fun ensureLoaded()
    fun create(modelId: ByteArray, cacheRoot: ByteArray?, directory: ByteArray?): Long
    fun destroy(handle: Long)
    fun isDownloaded(handle: Long): Int
    fun download(handle: Long): Int
    fun run(handle: Long, text: ByteArray, options: ByteArray?): ByteArray?
}

private object JniModelApi : NativeModelApi {
    override fun ensureLoaded() = DesertAntNative.ensureLoaded()
    override fun create(modelId: ByteArray, cacheRoot: ByteArray?, directory: ByteArray?) =
        DesertAntNative.create(modelId, cacheRoot, directory)
    override fun destroy(handle: Long) = DesertAntNative.destroy(handle)
    override fun isDownloaded(handle: Long) = DesertAntNative.isDownloaded(handle)
    override fun download(handle: Long) = DesertAntNative.download(handle)
    override fun run(handle: Long, text: ByteArray, options: ByteArray?) =
        DesertAntNative.run(handle, text, options)
}
