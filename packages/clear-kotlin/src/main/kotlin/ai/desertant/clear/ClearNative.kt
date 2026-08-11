package ai.desertant.clear

import ai.desertant.core.NativeLibraries
import ai.desertant.core.NativeModelApi

internal object ClearNative : NativeModelApi {
    override fun ensureLoaded() = NativeLibraries.loadModel("ClearAndroid")
    override external fun create(modelId: ByteArray, cacheRoot: ByteArray?, directory: ByteArray?): Long
    override external fun destroy(handle: Long)
    override external fun isDownloaded(handle: Long): Int
    override external fun download(handle: Long): Int
    override external fun run(handle: Long, input: ByteArray, options: ByteArray?): ByteArray?
}
