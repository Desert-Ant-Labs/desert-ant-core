package ai.desertant.tongue.usage

import java.util.Timer
import java.util.TimerTask

/**
 * Owns the turnstile for one `Tongue`: opened on construction, a call recorded per
 * detection, and a debounced flush that coalesces a burst of keystrokes into one
 * send.
 *
 * The equivalent of core's `TrackedSession`, which this SDK cannot use — that
 * wraps an `InferenceSession`, and there is no inference session here. See
 * docs/USAGE.md.
 *
 * `synchronized` rather than an actor or a coroutine scope: `UsageClient` is not
 * thread-safe, and the artifact takes no dependency on kotlinx-coroutines. The
 * critical section is a couple of integer comparisons.
 */
internal class UsageTurnstile internal constructor(
    private val client: UsageClient,
    /** The debounce. A parameter so a test can watch it fire without sleeping 3 s. */
    private val flushAfterMs: Long = FLUSH_AFTER_MS,
) {

    private val lock = Any()
    private var flushScheduled = false
    private var scheduledFlush: TimerTask? = null

    /** One detection. */
    fun record() {
        var task: TimerTask? = null
        synchronized(lock) {
            client.recordCall()
            if (flushScheduled) return
            flushScheduled = true
            task = object : TimerTask() {
                override fun run() {
                    synchronized(lock) {
                        flushScheduled = false
                        scheduledFlush = null
                        runCatching { client.flush() }
                    }
                }
            }
            scheduledFlush = task
        }
        // Scheduled outside the lock: the timer thread takes its own queue lock,
        // and a task of ours takes `lock` while running.
        task?.let { timer.schedule(it, flushAfterMs) }
    }

    /**
     * Send what this turnstile has recorded and block until the POST has finished,
     * so a JVM that exits right after a detection does not leave before it lands.
     * One load per device per call, whatever the re-emit window says: the forced
     * emit core's `flushTelemetry()` performs. Nothing recorded means nothing
     * sent, so an idle process never invents a billable load.
     */
    fun flushTelemetry(): Boolean = runCatching {
        val handle = synchronized(lock) {
            // Cancel the debounce: this call is the flush, and a timer left behind
            // would send again on its own.
            scheduledFlush?.cancel()
            scheduledFlush = null
            flushScheduled = false
            if (client.hasUsage()) client.load() else null
        }
        handle?.await()
        true
    }.getOrDefault(false)

    internal companion object {
        /** Debounce before flushing, matching core's `TrackedSession`. */
        private const val FLUSH_AFTER_MS = 3_000L

        /** Daemon so a short-lived process is never held open by a pending flush. */
        private val timer = Timer("tongue-usage-flush", true)

        /**
         * The turnstile for a new `Tongue`, or null when usage is switched off.
         *
         * Never throws: a model must still load if the store is unwritable or the
         * platform is unusual. A failure here means no reporting, not no detection.
         */
        fun create(context: Any?): UsageTurnstile? {
            if (usageDisabled()) return null
            return runCatching {
                val client = makeClient(context = context, sdkVersion = SDK_VERSION)
                client.start()
                val turnstile = UsageTurnstile(client)
                // A process that exits inside the 3 s debounce would otherwise send
                // nothing at all, while `start()` has already stamped the window —
                // so a short-lived JVM would report zero every day, permanently.
                // The hook flushes what it can on the way out.
                runCatching {
                    Runtime.getRuntime().addShutdownHook(
                        Thread { runCatching { synchronized(turnstile.lock) { client.flush() } } },
                    )
                }
                turnstile
            }.getOrNull()
        }
    }
}

/** Kept in step with the version in build.gradle.kts by `mise run set-version`. */
internal const val SDK_VERSION: String = "0.1.2"
