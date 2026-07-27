package ai.desertant.__MODEL__

import ai.desertant.core.FfiReader
import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** The result __PRODUCT__ produces. Keep in sync with the FFI payload in CABI.swift. */
data class __PRODUCT__Result(val label: String, val confidence: Double)

class __PRODUCT__Exception(message: String) : RuntimeException(message)

/**
 * On-device __DESCRIPTION_SHORT__.
 *
 * ```kotlin
 * val __MODEL__ = __PRODUCT__(context)
 * val result = __MODEL__.run("input")
 * __MODEL__.close()
 * ```
 */
class __PRODUCT__(context: Context, directory: String? = null) : AutoCloseable {
    private var handle: Long

    init {
        __PRODUCT__Native.ensureLoaded()
        HostBridge.preferences = context.getSharedPreferences("desert-ant", Context.MODE_PRIVATE)
        HostBridge.applicationId = context.packageName
        handle = __PRODUCT__Native.create(
            context.cacheDir.absolutePath.toByteArray(Charsets.UTF_8),
            directory?.toByteArray(Charsets.UTF_8))
        if (handle == 0L) throw __PRODUCT__Exception("failed to create __PRODUCT__")
    }

    /** Whether the model is present locally (no network). */
    fun isDownloaded(): Boolean = __PRODUCT__Native.isDownloaded(handle) != 0

    /** Download the model if needed. */
    suspend fun download() = withContext(Dispatchers.IO) {
        if (__PRODUCT__Native.download(handle) != 0) throw __PRODUCT__Exception("model download failed")
    }

    /** Run the model over [input]. */
    suspend fun run(input: String, minimumConfidence: Double = 0.0): __PRODUCT__Result? =
        withContext(Dispatchers.Default) {
            if (handle == 0L) throw __PRODUCT__Exception("__PRODUCT__ is closed")
            val bytes = __PRODUCT__Native.run(handle, input.toByteArray(Charsets.UTF_8), minimumConfidence)
                ?: return@withContext null
            decode(FfiReader(bytes))
        }

    private fun decode(r: FfiReader): __PRODUCT__Result? {
        if (r.int() == 0) return null
        return __PRODUCT__Result(r.string(), r.double())
    }

    override fun close() {
        if (handle != 0L) { __PRODUCT__Native.destroy(handle); handle = 0L }
    }
}
