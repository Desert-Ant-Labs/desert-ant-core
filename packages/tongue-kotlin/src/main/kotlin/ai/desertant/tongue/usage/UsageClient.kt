package ai.desertant.tongue.usage

/**
 * Client state machine for the usage turnstile: a Kotlin port of
 * desert-ant-core's `Sources/Usage/UsageClient.swift`.
 *
 * Transport- and storage-free by design: the caller injects a stable `deviceId`,
 * persisted-state access, a clock and a `send`. [makeClient] wires the defaults.
 *
 * Ported rather than bridged because this SDK's Kotlin is a direct port with no
 * Swift underneath. Behaviour is checked against the shared
 * vectors in `src/test/resources/usage_vectors.json`, which the JavaScript port
 * replays from `test/usage_vectors.json` byte for byte.
 */

/** A native/mobile install is persistent, so a device re-emits at most once a day. */
internal const val DAY_MS: Long = 24L * 60 * 60 * 1000

/** The UTC day (days since the epoch) an epoch-ms instant falls on. */
internal fun utcDay(epochMs: Long): Long = Math.floorDiv(epochMs, DAY_MS)

/** Persisted per install, across sessions. */
internal data class UsageState(
    /** Epoch ms we last emitted or went inactive (0 = never). Gates the next emit. */
    val lastActiveAt: Long = 0,
    /** Calls accrued during throttled sessions, awaiting the next emitted load. */
    val carryCallCount: Int = 0,
    /**
     * UTC day of the last turnstile; null = unknown, which reads as not emitted
     * today. Gates a turnstile on every UTC day of use, so every month of use has
     * one, even when a gap shorter than the window crosses midnight.
     */
    val lastEmitDay: Long? = null,
)

/** Everything the client needs from its host. Mirrors core's `ClientDeps`. */
internal class ClientDeps(
    val deviceId: String,
    // No key: this port's transport always sets an `Authorization` header.
    val appId: String? = null,
    val platform: String,
    val sdkVersion: String,
    /** Authoritative call count read at emit time; overrides recordCall when set. */
    val callCount: (() -> Int)? = null,
    /**
     * Default context attached to auto-emitted loads. Ignored while the context
     * opt-out is on (`DesertAnt.sendsDeviceContext`, `DAL_USAGE_CONTEXT_DISABLED`);
     * what it returns is sanitized (`sanitizeContext`).
     */
    val context: (() -> Map<String, String>?)? = null,
    val windowMs: Long = DAY_MS,
    val now: () -> Long,
    val loadState: () -> UsageState,
    val saveState: (UsageState) -> Unit,
    val send: (IngestBody) -> SendHandle?,
)

internal class UsageClient(private val deps: ClientDeps) {
    private var sessionCalls = 0      // recordCall accrued this session, not yet accounted
    private var pending: IngestEvent? = null // queued turnstile, awaiting first flush
    private var emitted = false       // did we open a turnstile this session?

    /** Host calls this once per detection to attribute to the turnstile. */
    fun recordCall(n: Int = 1) {
        if (n > 0) sessionCalls += n
    }

    /** Whether there is usage to report, so a forced flush never invents a call. */
    fun hasUsage(): Boolean = sessionCalls > 0 || deps.loadState().carryCallCount > 0

    /**
     * Queue a turnstile if this is a new UTC day or a new session (the window
     * elapsed since the app was last active). Call on every recorded call, not
     * only on init: a client started only when it opens never sees the next day.
     */
    fun start() {
        val st = deps.loadState()
        val now = deps.now()
        val today = utcDay(now)
        // Billing counts distinct devices per UTC month, so the first use of each
        // month must post. Gating on the UTC day guarantees it (months start on
        // day boundaries) and delivers carried calls on the next day of use.
        if (st.lastEmitDay == today && now - st.lastActiveAt < deps.windowMs) return
        // Reserve the slot up front so a second start now won't double-emit.
        deps.saveState(st.copy(lastActiveAt = now, lastEmitDay = today))
        queue()
    }

    /** Mark the app inactive (stamp the idle clock) and flush. */
    fun suspend() {
        val st = deps.loadState()
        deps.saveState(st.copy(lastActiveAt = deps.now()))
        flush()
    }

    /** Force a turnstile now, ignoring the window, and hand back the send in flight. */
    fun load(context: Map<String, String>? = null): SendHandle? {
        val st = deps.loadState()
        val now = deps.now()
        deps.saveState(st.copy(lastActiveAt = now, lastEmitDay = utcDay(now)))
        queue(context)
        return flush()
    }

    /** Flush any pending event, returning the send it started. */
    fun flush(): SendHandle? {
        val st = deps.loadState()

        val queued = pending
        if (queued != null) {
            // First flush of this session's turnstile: attach carry + session calls.
            pending = null
            var event = queued.copy(callCount = resolveCount(st.carryCallCount + sessionCalls))
            // An opt-out set during the debounce still applies to the queued event.
            if (deviceContextDisabled()) event = event.copy(context = null)
            if (deps.callCount == null) {
                deps.saveState(st.copy(carryCallCount = 0))
            }
            sessionCalls = 0
            return deps.send(makeBody(listOf(event)))
        }

        if (emitted && sessionCalls > 0) {
            // Turnstile already sent; late calls ride a delta load (server sums them).
            val event = IngestEvent(
                deviceId = deps.deviceId,
                callCount = resolveCount(sessionCalls),
                context = currentContext(),
            )
            sessionCalls = 0
            return deps.send(makeBody(listOf(event)))
        }

        if (!emitted && sessionCalls > 0 && deps.callCount == null) {
            // Throttled session: no turnstile today. Carry the calls to the next emit.
            deps.saveState(st.copy(carryCallCount = st.carryCallCount + sessionCalls))
            sessionCalls = 0
        }
        return null
    }

    // Provider is authoritative when set, else the accumulated (carry + session)
    // count. Zero is omitted from the wire.
    private fun resolveCount(accumulated: Int): Int? {
        val n = deps.callCount?.invoke() ?: accumulated
        return if (n > 0) n else null
    }

    // Every context is sanitized before it is queued, because the ingest rejects
    // the whole batch over an oversized one (see `sanitizeContext`). A provider
    // that throws costs the context, never the event.
    private fun currentContext(): Map<String, String>? {
        if (deviceContextDisabled()) return null
        return runCatching { sanitizeContext(deps.context?.invoke()) }.getOrNull()
    }

    private fun queue(context: Map<String, String>? = null) {
        // The opt-out is enforced at flush, for an explicit context too.
        val explicit = context?.let(::sanitizeContext)
        pending = IngestEvent(deviceId = deps.deviceId, context = if (context != null) explicit else currentContext())
        emitted = true
    }

    private fun makeBody(events: List<IngestEvent>) = IngestBody(
        platform = deps.platform,
        app = deps.appId?.let(::AppInfo),
        sdk = SdkInfo(version = deps.sdkVersion),
        sentAt = iso8601(deps.now()),
        events = events,
    )
}
