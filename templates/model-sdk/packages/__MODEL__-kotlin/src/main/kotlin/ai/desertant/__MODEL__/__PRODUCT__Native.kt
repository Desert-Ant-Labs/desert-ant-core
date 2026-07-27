package ai.desertant.__MODEL__

import ai.desertant.core.HostBridge

/**
 * JNI surface over `lib__PRODUCT__Android.so`, built by `mise run android-natives`.
 * Android only: the library statically links its Swift runtime but dynamically
 * depends on `libLiteRt.so`, so that must load first.
 *
 * `regexMatches` / `jsonParseTree` / `normalizeNfkc` / `httpTree` / `httpDownload`
 * are the host callbacks the native runtime looks up on this class. They forward
 * to `ai.desertant.core.HostBridge`. The core installs all of them
 * unconditionally, so every forwarder must be present even if unused here.
 */
internal object __PRODUCT__Native {
    @Volatile private var loaded = false

    fun ensureLoaded() {
        if (loaded) return
        synchronized(this) {
            if (loaded) return
            System.loadLibrary("LiteRt")
            System.loadLibrary("__PRODUCT__Android")
            loaded = true
        }
    }

    @JvmStatic external fun create(cacheRoot: ByteArray?, directory: ByteArray?): Long
    @JvmStatic external fun createBundled(metaJson: ByteArray, model: ByteArray): Long
    @JvmStatic external fun destroy(handle: Long)
    @JvmStatic external fun isDownloaded(handle: Long): Int
    @JvmStatic external fun download(handle: Long): Int
    @JvmStatic external fun run(handle: Long, input: ByteArray, minimumConfidence: Double): ByteArray?

    @JvmStatic
    fun regexMatches(patternUtf8: ByteArray, caseInsensitive: Boolean, textUtf8: ByteArray, firstOnly: Boolean): ByteArray =
        HostBridge.regexMatches(patternUtf8, caseInsensitive, textUtf8, firstOnly)

    @JvmStatic
    fun jsonParseTree(jsonUtf8: ByteArray): ByteArray = HostBridge.jsonParseTree(jsonUtf8)

    @JvmStatic
    fun httpTree(urlUtf8: ByteArray): ByteArray = HostBridge.httpTree(urlUtf8)

    @JvmStatic
    fun httpDownload(urlUtf8: ByteArray, destUtf8: ByteArray): Int = HostBridge.httpDownload(urlUtf8, destUtf8)

    @JvmStatic
    fun normalizeNfkc(textUtf8: ByteArray): ByteArray = HostBridge.normalizeNfkc(textUtf8)
}
