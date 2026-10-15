package ai.desertant.core.androidtest

/**
 * Loads the cross-compiled Swift JNI library (libCoreAndroidTests.so, staged
 * into jniLibs by `mise run test:android`) and exposes its entry point.
 */
object CoreBridge {
    init { System.loadLibrary("CoreAndroidTests") }

    /**
     * Installs the CHostBridge callbacks against [host] (pass
     * `DesertAntNative::class.java`) and runs the host-backed integration checks
     * (Regex, JSON decode, NFKC). Returns "" when all pass, or a ` | `-separated
     * summary of the failures.
     */
    @JvmStatic external fun runChecks(host: Class<*>): String

    /**
     * Installs the callbacks against [host] and POSTs a small JSON body with
     * `Authorization: Bearer pk_test` to [url] (UTF-8) through the Swift HTTP client, the path every license
     * request takes. Returns `"<status> <body>"`, or `"error: ..."` with no response.
     */
    @JvmStatic external fun post(host: Class<*>, url: ByteArray): String

    // Whether the Swift core accepts the license [token] under the `kid=key` lines in [keys] (both UTF-8).
    @JvmStatic external fun verifyLicense(host: Class<*>, token: ByteArray, keys: ByteArray): Boolean
}
