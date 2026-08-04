package ai.desertant.redact

import ai.desertant.core.HostBridge

/**
 * JNI surface over `libRedactAndroid.so`, built by `mise run android-natives`.
 * Android only: `libRedactAndroid.so` statically links its runtime.
 * Instance-based: each `Redact` is an opaque native handle (a `Long`). Text
 * crosses as UTF-8 bytes; the redaction result comes back as an FFIBuffer typed
 * binary buffer.
 *
 * `regexMatches` / `jsonParseTree` / `normalizeNfkc` / `httpTree` / `httpDownload` are the host
 * callbacks the native runtime looks up on this class. They forward to
 * `ai.desertant.core.HostBridge`.
 */
internal object RedactNative {
    @Volatile private var loaded = false

    fun ensureLoaded() {
        if (loaded) return
        synchronized(this) {
            if (loaded) return
            // libRedactAndroid.so links libLiteRt.so (the LiteRT runtime); load it
            // first so the dependency is resolvable regardless of link order.
            System.loadLibrary("LiteRt")
            System.loadLibrary("RedactAndroid")
            loaded = true
        }
    }

    @JvmStatic external fun create(cacheRoot: ByteArray?, directory: ByteArray?): Long
    @JvmStatic external fun createBundled(tokenizer: ByteArray, labelsJson: ByteArray, model: ByteArray): Long
    @JvmStatic external fun destroy(handle: Long)
    @JvmStatic external fun isDownloaded(handle: Long): Int
    @JvmStatic external fun download(handle: Long): Int
    @JvmStatic external fun run(handle: Long, textUtf8: ByteArray, minimumConfidence: Double, labelsCsv: ByteArray?): ByteArray?

    @JvmStatic
    fun regexMatches(patternUtf8: ByteArray, caseInsensitive: Boolean, textUtf8: ByteArray, firstOnly: Boolean): ByteArray =
        HostBridge.regexMatches(patternUtf8, caseInsensitive, textUtf8, firstOnly)

    @JvmStatic
    fun jsonParseTree(jsonUtf8: ByteArray): ByteArray = HostBridge.jsonParseTree(jsonUtf8)

    // HTTP host callbacks the Swift ModelStore uses to download on demand.
    @JvmStatic
    fun httpTree(urlUtf8: ByteArray): ByteArray = HostBridge.httpTree(urlUtf8)

    @JvmStatic
    fun httpDownload(urlUtf8: ByteArray, destUtf8: ByteArray): Int = HostBridge.httpDownload(urlUtf8, destUtf8)

    @JvmStatic
    fun normalizeNfkc(textUtf8: ByteArray): ByteArray = HostBridge.normalizeNfkc(textUtf8)
}
