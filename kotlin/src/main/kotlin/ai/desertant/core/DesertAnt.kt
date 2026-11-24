package ai.desertant.core

import android.content.Context

/**
 * Process-wide Desert Ant configuration. Call once at launch, before the first model call:
 *
 * ```kotlin
 * DesertAnt.configure(apiKey = "dal_...")
 * ```
 */
object DesertAnt {
    @Volatile
    private var configuredApiKey: String? = null

    internal val currentApiKey: String? get() = configuredApiKey

    /** Sets the API key that license requests send. */
    @JvmStatic
    fun configure(apiKey: String) {
        configuredApiKey = apiKey
    }

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

    /**
     * The last 256 model calls in this process, oldest first, each with the
     * processors its graphs ran on: CPU, GPU, or both when LiteRT split a
     * graph or a model runs several. Pass a catalog id (`"eye"`) to keep one
     * model's.
     *
     * Optional, and meant for debugging: nothing needs it to run a model. The
     * history lives in memory only, is never sent anywhere, and starts empty
     * in every process. A graph a model runs off the call's own task may be
     * missing from its record. On an emulator every graph runs on the CPU.
     */
    @JvmStatic
    @JvmOverloads
    fun recentRuns(modelId: String? = null): List<RunRecord> = RunHistory.snapshot(modelId)

    /** Empty the [recentRuns] history, for example between two measurements. */
    @JvmStatic
    fun clearRecentRuns() = RunHistory.clear()

    /**
     * Check how the app set up the SDK, and return one message per problem,
     * or an empty list when there is none. Each problem also goes to logcat
     * (or to [logger]) as a warning, whatever [logLevel] says; a clean result
     * is logged as information, which [logLevel] can silence.
     *
     * It checks that the APK carries LiteRT and the GPU accelerator for the
     * ABI the app runs, that every model library is built for that ABI, that
     * [configure] set an API key, and that the app holds the INTERNET permission.
     *
     * Optional, and meant for debugging. It reads the APKs' zip directories,
     * so call it off the main thread.
     */
    @JvmStatic
    fun checkHealth(context: Context): List<String> {
        val issues = Health.issues(Health.inputs(context))
        if (issues.isEmpty()) {
            if (logLevel <= LogLevel.INFO) SdkLog.write(LogLevel.INFO, "health", "no issues found")
        } else {
            issues.forEach { SdkLog.write(LogLevel.WARNING, "health", it) }
        }
        return issues
    }
}

/** How much the SDK says, from the most talkative to silent. */
enum class LogLevel {
    DEBUG, INFO, WARNING, ERROR, OFF
}
