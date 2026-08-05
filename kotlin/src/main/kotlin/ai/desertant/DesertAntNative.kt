package ai.desertant

import ai.desertant.core.HostBridge

/**
 * Host callbacks shared by every model-specific JNI library. Native model code
 * finds this class explicitly, so model bridge classes contain only their own
 * create/run symbols while regex, JSON, HTTP, storage, and audio stay here once.
 */
object DesertAntNative {

    @JvmStatic
    fun regexMatches(
        patternUtf8: ByteArray,
        caseInsensitive: Boolean,
        textUtf8: ByteArray,
        firstOnly: Boolean,
    ): ByteArray = HostBridge.regexMatches(patternUtf8, caseInsensitive, textUtf8, firstOnly)

    @JvmStatic
    fun jsonParseTree(jsonUtf8: ByteArray): ByteArray = HostBridge.jsonParseTree(jsonUtf8)

    @JvmStatic
    fun normalizeNfkc(textUtf8: ByteArray): ByteArray = HostBridge.normalizeNfkc(textUtf8)

    // HTTP host callbacks the Swift ModelStore uses to download on demand.
    @JvmStatic
    fun httpTree(urlUtf8: ByteArray): ByteArray = HostBridge.httpTree(urlUtf8)

    @JvmStatic
    fun httpDownload(urlUtf8: ByteArray, destUtf8: ByteArray): Int =
        HostBridge.httpDownload(urlUtf8, destUtf8)

    // Usage state persistence + app identity (SharedPreferences via the host app).
    @JvmStatic
    fun prefsGet(keyUtf8: ByteArray): ByteArray = HostBridge.prefsGet(keyUtf8)

    @JvmStatic
    fun prefsSet(keyUtf8: ByteArray, valueUtf8: ByteArray) = HostBridge.prefsSet(keyUtf8, valueUtf8)

    @JvmStatic
    fun appId(): ByteArray = HostBridge.appId()
}
