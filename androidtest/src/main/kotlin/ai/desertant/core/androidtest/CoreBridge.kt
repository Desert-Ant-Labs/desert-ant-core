package ai.desertant.core.androidtest

/**
 * Loads the cross-compiled Swift JNI library (libCoreAndroidTests.so, staged
 * into jniLibs by `mise run test-android`) and exposes its entry point.
 */
object CoreBridge {
    init { System.loadLibrary("CoreAndroidTests") }

    /**
     * Installs the CHostBridge callbacks against [host] (pass
     * `HostBridge::class.java`) and runs the host-backed integration checks
     * (Regex, JSON decode, NFKC). Returns "" when all pass, or a ` | `-separated
     * summary of the failures.
     */
    @JvmStatic external fun runChecks(host: Class<*>): String
}
