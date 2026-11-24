package ai.desertant.core

/** Loads the one shared LiteRT runtime and any number of model-specific JNI libraries. */
object NativeLibraries {
    private val verified = mutableSetOf<String>()

    // Inlined into each model, so this body runs against whatever core the app
    // ships. On the mismatch path it calls only sdkVersion(), which keeps its
    // JVM signature forever. The messages are spelled out for the same reason.
    inline fun loadModel(library: String, modelVersion: String, crossinline nativeVersion: () -> ByteArray?) {
        val core = try {
            sdkVersion()
        } catch (missing: NoSuchMethodError) {
            throw IllegalStateException(
                "Desert Ant SDK version mismatch for $library: model artifact $modelVersion, " +
                    "core (version unavailable). Align all ai.desertant dependencies with ai.desertant:bom.",
                missing,
            )
        }
        if (modelVersion != core) {
            throw IllegalStateException(
                "Desert Ant SDK version mismatch for $library: model artifact $modelVersion, " +
                    "core $core. Align all ai.desertant dependencies with ai.desertant:bom.",
            )
        }
        // Only reached when the versions match, so the signature can change.
        loadVersionedModel(library, core) { nativeVersion() }
    }

    /** Called from model bytecode. Its JVM signature must never change. */
    @PublishedApi
    internal fun sdkVersion(): String = SDK_VERSION

    @PublishedApi
    @Synchronized
    internal fun loadVersionedModel(library: String, coreVersion: String, nativeVersion: () -> ByteArray?) {
        if (library in verified) return
        if (verified.isEmpty()) System.loadLibrary("LiteRt")
        System.loadLibrary(library)
        val version = try {
            nativeVersion()?.decodeToString()
        } catch (missing: UnsatisfiedLinkError) {
            throw IllegalStateException(sdkVersionError(library, "native library", null, coreVersion), missing)
        }
        requireSdkVersion(library, "native library", version, coreVersion)
        verified.add(library)
    }
}

internal fun requireSdkVersion(library: String, artifact: String, version: String?, coreVersion: String) {
    check(version == coreVersion) { sdkVersionError(library, artifact, version, coreVersion) }
}

internal fun sdkVersionError(library: String, artifact: String, version: String?, coreVersion: String): String =
    "Desert Ant SDK version mismatch for $library: $artifact ${version ?: "(version unavailable)"}, " +
        "core $coreVersion. Align all ai.desertant dependencies with ai.desertant:bom."
