package ai.desertant

import ai.desertant.core.DesertAnt
import ai.desertant.core.HostBridge
import ai.desertant.core.LogLevel
import ai.desertant.core.RunHistory
import ai.desertant.core.SdkLog

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
    fun caseFold(textUtf8: ByteArray): ByteArray = HostBridge.caseFold(textUtf8)

    @JvmStatic
    fun normalizeNfkc(textUtf8: ByteArray): ByteArray = HostBridge.normalizeNfkc(textUtf8)

    @JvmStatic
    fun normalizeNfc(textUtf8: ByteArray): ByteArray = HostBridge.normalizeNfc(textUtf8)

    // HTTP host callbacks the Swift ModelStore uses to download on demand.
    @JvmStatic
    fun httpTree(urlUtf8: ByteArray): ByteArray = HostBridge.httpTree(urlUtf8)

    @JvmStatic
    fun httpDownload(urlUtf8: ByteArray, destUtf8: ByteArray): Int =
        HostBridge.httpDownload(urlUtf8, destUtf8)

    // HTTP request callback the Swift license client POSTs through.
    @JvmStatic
    fun httpRequest(
        methodUtf8: ByteArray,
        urlUtf8: ByteArray,
        body: ByteArray?,
        contentTypeUtf8: ByteArray?,
        headersUtf8: ByteArray?,
    ): ByteArray? = HostBridge.httpRequest(methodUtf8, urlUtf8, body, contentTypeUtf8, headersUtf8)

    // Install id and license persistence + app identity (SharedPreferences via the host app).
    @JvmStatic
    fun prefsGet(keyUtf8: ByteArray): ByteArray = HostBridge.prefsGet(keyUtf8)

    @JvmStatic
    fun prefsSet(keyUtf8: ByteArray, valueUtf8: ByteArray) = HostBridge.prefsSet(keyUtf8, valueUtf8)

    @JvmStatic
    fun appId(): ByteArray = HostBridge.appId()

    @JvmStatic
    fun apiKey(): ByteArray = (DesertAnt.currentApiKey ?: "").toByteArray(Charsets.UTF_8)

    @JvmStatic
    fun verifyLicense(signature: ByteArray, message: ByteArray, publicKey: ByteArray): Boolean =
        HostBridge.verifyLicense(signature, message, publicKey)

    // The log level the host app set, as the core's LogLevel raw value.
    @JvmStatic
    fun logLevel(): Int = DesertAnt.logLevel.ordinal

    // Every message the core writes: the app's logger when it set one, else logcat.
    @JvmStatic
    fun log(level: Int, sourceUtf8: ByteArray, messageUtf8: ByteArray) {
        SdkLog.write(
            LogLevel.entries.getOrElse(level) { LogLevel.ERROR },
            sourceUtf8.toString(Charsets.UTF_8),
            messageUtf8.toString(Charsets.UTF_8),
        )
    }

    // One model call's record, for DesertAnt.recentRuns(). Called on the thread
    // that made the call, right after it returns.
    @JvmStatic
    fun recordRun(modelIdUtf8: ByteArray, record: ByteArray) {
        val run = try {
            RunHistory.decode(modelIdUtf8.toString(Charsets.UTF_8), record, System.currentTimeMillis())
        } catch (_: RuntimeException) {
            null  // a malformed record costs the history one entry, never the call
        } ?: return
        RunHistory.add(run)
    }
}
