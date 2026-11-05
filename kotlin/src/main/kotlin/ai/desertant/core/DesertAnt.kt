package ai.desertant.core

/**
 * Process-wide Desert Ant configuration, for hosts where an environment
 * variable is not a natural fit (an Android app has no launch environment of
 * its own). Set once at launch, before the first model call:
 *
 * ```kotlin
 * DesertAnt.apiKey = "pk_live_..."
 * ```
 *
 * Mirrors core's Swift `DesertAnt.apiKey`, and covers every model in the app.
 * The key is read on each model load, when the SDK requests or activates that
 * model's license. Null (the default) or blank means unset, and the license is
 * activated without a key.
 */
object DesertAnt {
    /** The publishable API key sent with license grants and activations. Null means unset. */
    @JvmStatic
    @Volatile
    var apiKey: String? = null

    /**
     * The least severe level the SDK writes, for every model in the app: the
     * SDK's own messages and the runtime's. [LogLevel.WARNING] by default. Set
     * it before the first model loads; the native core reads it then.
     */
    @JvmStatic
    @Volatile
    var logLevel: LogLevel = LogLevel.WARNING

    /**
     * Receives every message instead of logcat: the level, what wrote it
     * (`core`, `http`, `litert`, a model id), and the message. Null (the
     * default) writes to logcat under the `DesertAnt` tag. Called on whatever
     * thread logged, which may be a runtime's worker.
     */
    @JvmStatic
    @Volatile
    var logger: ((level: LogLevel, source: String, message: String) -> Unit)? = null
}

/** How much the SDK says, from the most talkative to silent. */
enum class LogLevel {
    DEBUG, INFO, WARNING, ERROR, OFF
}
