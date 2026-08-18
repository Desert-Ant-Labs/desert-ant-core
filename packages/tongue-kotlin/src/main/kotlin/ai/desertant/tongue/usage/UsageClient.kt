package ai.desertant.tongue.usage

/**
 * Client state machine for the usage turnstile — a Kotlin port of
 * desert-ant-core's `Sources/Usage/UsageClient.swift`.
 *
 * Transport- and storage-free by design: the caller injects a stable `deviceId`,
 * persisted-state access, a clock and a `send`. [makeClient] wires the defaults.
 *
 * Ported rather than bridged because this SDK's Kotlin is a direct port with no
 * Swift underneath — see docs/USAGE.md. Behaviour is checked against the shared
 * vectors in `src/test/resources/usage_vectors.json`, which the JavaScript port
 * replays from `test/usage_vectors.json` byte for byte.
 */

/** A native/mobile install is persistent, so a device re-emits at most once a day. */
internal const val DAY_MS: Long = 24L * 60 * 60 * 1000

/** Persisted per install, across sessions. */
internal data class UsageState(
    /** Epoch ms we last emitted or went inactive (0 = never). Gates the next emit. */
    val lastActiveAt: Long = 0,
    /** Calls accrued during throttled sessions, awaiting the next emitted load. */
    val carryCallCount: Int = 0,
)

/** Everything the client needs from its host. Mirrors core's `ClientDeps`. */
internal class ClientDeps(
    val deviceId: String,
    val key: String? = null,
    val appId: String? = null,
    val platform: String,
    val sdkVersion: String,
    /** Authoritative call count read at emit time; overrides recordCall when set. */
    val callCount: (() -> Int)? = null,
    val context: (() -> Map<String, String>?)? = null,
    val windowMs: Long = DAY_MS,
    val now: () -> Long,
    val loadState: () -> UsageState,
    val saveState: (UsageState) -> Unit,
    val send: (IngestBody) -> Unit,
)

internal class UsageClient(private val deps: ClientDeps) {
    private var sessionCalls = 0      // recordCall accrued this session, not yet accounted
    private var pending: IngestEvent? = null // queued turnstile, awaiting first flush
    private var emitted = false       // did we open a turnstile this session?

    /** Host calls this once per detection to attribute to the turnstile. */
    fun recordCall(n: Int = 1) {
        if (n > 0) sessionCalls += n
    }

    /**
     * Evaluate the window and, if a new day is due, queue a turnstile.
     * Call on init and again on reactivation.
     */
    fun start() {
        val st = deps.loadState()
        if (deps.now() - st.lastActiveAt < deps.windowMs) return // still within the same day
        // Reserve the slot up front so a second start now won't double-emit.
        deps.saveState(UsageState(deps.now(), st.carryCallCount))
        queue()
    }

    /** Mark the app inactive (stamp the idle clock) and flush. */
    fun suspend() {
        val st = deps.loadState()
        deps.saveState(UsageState(deps.now(), st.carryCallCount))
        flush()
    }

    /** Force a turnstile now, ignoring the window. */
    fun load(context: Map<String, String>? = null) {
        val st = deps.loadState()
        deps.saveState(UsageState(deps.now(), st.carryCallCount))
        queue(context)
        flush()
    }

    /** Flush any pending event. */
    fun flush() {
        val st = deps.loadState()

        val queued = pending
        if (queued != null) {
            // First flush of this session's turnstile: attach carry + session calls.
            pending = null
            val event = queued.copy(callCount = resolveCount(st.carryCallCount + sessionCalls))
            if (deps.callCount == null) {
                deps.saveState(UsageState(st.lastActiveAt, 0))
            }
            sessionCalls = 0
            deps.send(makeBody(listOf(event)))
            return
        }

        if (emitted && sessionCalls > 0) {
            // Turnstile already sent; late calls ride a delta load (server sums them).
            val event = IngestEvent(
                deviceId = deps.deviceId,
                callCount = resolveCount(sessionCalls),
                context = currentContext(),
            )
            sessionCalls = 0
            deps.send(makeBody(listOf(event)))
            return
        }

        if (!emitted && sessionCalls > 0 && deps.callCount == null) {
            // Throttled session: no turnstile today. Carry the calls to the next emit.
            deps.saveState(UsageState(st.lastActiveAt, st.carryCallCount + sessionCalls))
            sessionCalls = 0
        }
    }

    // Provider is authoritative when set, else the accumulated (carry + session)
    // count. Zero is omitted from the wire.
    private fun resolveCount(accumulated: Int): Int? {
        val n = deps.callCount?.invoke() ?: accumulated
        return if (n > 0) n else null
    }

    private fun currentContext(): Map<String, String>? = deps.context?.invoke()

    private fun queue(context: Map<String, String>? = null) {
        pending = IngestEvent(deviceId = deps.deviceId, context = context ?: currentContext())
        emitted = true
    }

    private fun makeBody(events: List<IngestEvent>) = IngestBody(
        platform = deps.platform,
        key = deps.key,
        app = deps.appId?.let(::AppInfo),
        sdk = SdkInfo(version = deps.sdkVersion),
        sentAt = iso8601(deps.now()),
        events = events,
    )
}
