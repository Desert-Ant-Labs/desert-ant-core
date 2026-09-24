package ai.desertant.core.androidtest

/**
 * Loads the cross-compiled Swift JNI library (libCoreAndroidTests.so, staged
 * into jniLibs by `mise run test:android`) and exposes its entry point.
 */
object CoreBridge {
    init { System.loadLibrary("CoreAndroidTests") }

    /**
     * Installs the CHostBridge callbacks against [host] (pass
     * `DesertAntNative::class.java`: HostBridge's opt-out is a property, so it
     * has no `sendsDeviceContext()` for JNI to find) and runs the host-backed integration checks
     * (Regex, JSON decode, NFKC). Returns "" when all pass, or a ` | `-separated
     * summary of the failures.
     */
    @JvmStatic external fun runChecks(host: Class<*>): String

    /**
     * Installs the callbacks against [host] and returns the usage context a
     * client on this device would send, as sorted `key=value` lines ("" for
     * none). Call [ai.desertant.core.HostBridge.attach] first for the facts.
     */
    @JvmStatic external fun usageContext(host: Class<*>): String

    /**
     * Installs the callbacks against [host] and POSTs a small JSON body with
     * `Authorization: Bearer pk_test` to [url] (UTF-8) through the Swift HTTP client, the path every usage send
     * takes. Returns `"<status> <body>"`, or `"error: ..."` with no response.
     */
    @JvmStatic external fun post(host: Class<*>, url: ByteArray): String
}
