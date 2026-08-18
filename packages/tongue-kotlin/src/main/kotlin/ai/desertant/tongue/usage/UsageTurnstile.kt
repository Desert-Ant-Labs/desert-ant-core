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
internal class UsageTurnstile private constructor(private val client: UsageClient) {

    private val lock = Any()
    private var flushScheduled = false

    /** One detection. */
    fun record() {
        synchronized(lock) {
            client.recordCall()
            if (flushScheduled) return
            flushScheduled = true
        }
        timer.schedule(
            object : TimerTask() {
                override fun run() {
                    synchronized(lock) {
                        flushScheduled = false
                        runCatching { client.flush() }
                    }
                }
            },
            FLUSH_AFTER_MS,
        )
    }

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
