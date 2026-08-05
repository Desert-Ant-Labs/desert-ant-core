package ai.desertant

import ai.desertant.core.HostBridge

/**
 * The JNI surface over `libDesertAntAndroid.so` - one native class for every
 * Desert Ant model, not one per model.
 *
 * The Swift side derives its JNI symbols from this class name
 * (`Java_ai_desertant_DesertAntNative_*` in Sources/Bindings/AndroidJNI.swift),
 * and the model is a `modelId` argument to a model-agnostic C ABI. A model's
 * options and results cross as `FfiWriter`/`FfiReader` payloads whose schema
 * belongs to the model, so adding a model adds no native symbol, no native
 * library, and no Kotlin class here.
 *
 * The library statically links its Swift runtime but dynamically depends on
 * `libLiteRt.so`, so that must load first ([ensureLoaded] does it in order).
 *
 * The `@JvmStatic` forwarders at the bottom are the host callbacks the native
 * runtime looks up **on this class** (see `installHostBridge`): a pure-Swift core
 * must not link Foundation on Android, so its regex, JSON, NFKC, HTTP, and usage
 * persistence primitives call back into the platform through these. They must all
 * be present, and named exactly as below, even for a model that does not use one.
 *
 * Internal to the SDKs; apps use `Emo`, `Redact`, and friends.
 */
object DesertAntNative {
    @Volatile private var loaded = false

    /** Load the native libraries once, LiteRT runtime first. */
    fun ensureLoaded() {
        if (loaded) return
        synchronized(this) {
            if (loaded) return
            // Load the LiteRT runtime first so libDesertAntAndroid.so's
            // DT_NEEDED libLiteRt.so resolves.
            System.loadLibrary("LiteRt")
            System.loadLibrary("DesertAntAndroid")
            loaded = true
        }
    }

    /**
     * Create a model against the model store. [modelId] is the catalog id
     * (`"emo"`, `"redact"`, ...), [cacheRoot] the app cache dir, [directory] an
     * explicit model home or null for the managed layout. Returns 0 on failure
     * (including an unknown [modelId]). Loading is lazy, as in the Swift SDK.
     */
    @JvmStatic external fun create(modelId: ByteArray, cacheRoot: ByteArray?, directory: ByteArray?): Long

    @JvmStatic external fun destroy(handle: Long)

    @JvmStatic external fun isDownloaded(handle: Long): Int

    /** Blocking; call off the main thread. 0 on success. */
    @JvmStatic external fun download(handle: Long): Int

    /**
     * Run the model over [textUtf8] with the model's own [options] payload,
     * returning the model's own result payload (read it with
     * [ai.desertant.core.FfiReader]), or null on failure.
     */
    @JvmStatic external fun run(handle: Long, textUtf8: ByteArray, options: ByteArray?): ByteArray?

    // MARK: host callbacks, looked up on this class by installHostBridge

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
