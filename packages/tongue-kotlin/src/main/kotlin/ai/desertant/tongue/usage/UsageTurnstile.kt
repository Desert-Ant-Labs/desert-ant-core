package ai.desertant.tongue.usage

import java.util.Timer
import java.util.TimerTask

/**
 * Owns the turnstile for one `Tongue`: opened on the first detection, a call
 * recorded per detection, and a debounced flush that coalesces a burst of
 * keystrokes into one send. Until the first detection no client is built, so
 * no store is touched and no device id is minted.
 *
 * The equivalent of core's `TrackedSession`, which this SDK cannot use: that
 * wraps an `InferenceSession`, and there is no inference session here.
 *
 * `synchronized` rather than an actor or a coroutine scope: `UsageClient` is not
 * thread-safe, and the artifact takes no dependency on kotlinx-coroutines. The
 * critical section is a couple of integer comparisons.
 */
internal class UsageTurnstile private constructor(
    /** Builds and starts the client, under the lock; retried on the next detection if it throws. */
    private val open: () -> UsageClient,
    /** The debounce. A parameter so a test can watch it fire without sleeping 3 s. */
    private val flushAfterMs: Long,
) {
    /** A turnstile over a client already built, for tests. */
    internal constructor(
        client: UsageClient,
        flushAfterMs: Long = FLUSH_AFTER_MS,
    ) : this({ client }, flushAfterMs)

    private val lock = Any()

    /** Null until the first recorded call; a build that threw is tried again on the next one. */
    private var client: UsageClient? = null

    /** The client, built on first use. Under the lock. */
    private fun openClient(): UsageClient? {
        if (client == null) client = runCatching { open() }.getOrNull()
        return client
    }
    private var flushScheduled = false
    private var scheduledFlush: TimerTask? = null

    /**
     * The newest send this turnstile started, from the debounce or a flush. The
     * next flush awaits it: the timer may have fired just before, or an earlier
     * flush may have given up at its deadline, leaving a POST in flight with
     * nothing left to send. Only the newest is kept: the real sender is one
     * thread, so it finishing means every earlier one has.
     */
    private var lastSend: SendHandle? = null

    /** One detection. */
    fun record() {
        synchronized(lock) {
            val client = openClient() ?: return
            // Every detection, not only when the client opens: one opened on a day that
            // had already posted would otherwise carry its calls past midnight, forever.
            runCatching { client.start() }
            client.recordCall()
            if (flushScheduled) return
            val task = object : TimerTask() {
                override fun run() {
                    synchronized(lock) {
                        flushScheduled = false
                        scheduledFlush = null
                        runCatching { client.flush() }.getOrNull()?.let { lastSend = it }
                    }
                }
            }
            // Scheduled under the lock, so `flushTelemetry` cannot cancel the task
            // before it is scheduled, which makes `schedule` throw out of `detect`.
            // No deadlock: the timer runs a task outside its own queue lock.
            // `runCatching` covers a timer that has died; the call stays recorded
            // and the next flush sends it.
            if (runCatching { timer.schedule(task, flushAfterMs) }.isSuccess) {
                flushScheduled = true
                scheduledFlush = task
            }
        }
    }

    /**
     * Send what this turnstile has recorded and block until the POST has finished,
     * so a JVM that exits right after a detection does not leave before it lands.
     * One load per device per call, whatever the re-emit window says: the forced
     * emit core's `flushTelemetry()` performs. Nothing recorded means nothing
     * sent, so an idle process never invents a billable load.
     */
    fun flushTelemetry(): Boolean = runCatching {
        val handles = synchronized(lock) {
            // Cancel the debounce: this call is the flush, and a timer left behind
            // would send again on its own.
            scheduledFlush?.cancel()
            scheduledFlush = null
            flushScheduled = false
            val client = client
            val forced = if (client != null && client.hasUsage()) client.load() else null
            listOfNotNull(lastSend, forced).also { lastSend = forced ?: lastSend }
        }
        handles.awaitAll()
        true
    }.getOrDefault(false)

    /**
     * The shutdown hook's flush. Unlike `flushTelemetry` it keeps the re-emit
     * window (`flush`, not `load`), but it too awaits the POST: the sender is a
     * daemon thread, and the JVM halts as soon as the hooks return, so a send
     * only started here would never leave the process.
     */
    internal fun flushOnExit() {
        runCatching {
            val handles = synchronized(lock) {
                scheduledFlush?.cancel()
                scheduledFlush = null
                flushScheduled = false
                val client = client
                val flushed = if (client == null) null else runCatching { client.flush() }.getOrNull()
                listOfNotNull(lastSend, flushed).also { lastSend = flushed ?: lastSend }
            }
            handles.awaitAll()
        }
    }

    internal companion object {
        /** Debounce before flushing, matching core's `TrackedSession`. */
        private const val FLUSH_AFTER_MS = 3_000L

        /** Daemon so a short-lived process is never held open by a pending flush. */
        private val timer = Timer("tongue-usage-flush", true)

        /**
         * The turnstile for a new `Tongue`.
         *
         * Never throws: a model must still load if the store is unwritable or the
         * platform is unusual. A failure building the client means no reporting,
         * not no detection. `storage` replaces the platform store (tests).
         */
        fun create(context: Any?, storage: UsageStorage? = null): UsageTurnstile {
            lateinit var turnstile: UsageTurnstile
            turnstile = UsageTurnstile(
                open = {
                    val client = makeClient(
                        context = context,
                        sdkVersion = SDK_VERSION,
                        storage = storage ?: defaultStorage(context),
                    )
                    client.start()
                    // A process that exits inside the 3 s debounce would otherwise send
                    // nothing at all, while `start()` has already stamped the window,
                    // so a short-lived JVM would report zero every day, permanently.
                    // The hook flushes what it can on the way out.
                    runCatching {
                        Runtime.getRuntime().addShutdownHook(Thread { turnstile.flushOnExit() })
                    }
                    client
                },
                flushAfterMs = FLUSH_AFTER_MS,
            )
            return turnstile
        }
    }
}

/** Kept in step with the version in build.gradle.kts by `mise run set-version`. */
internal const val SDK_VERSION: String = "4.0.0"
