// On-demand telemetry flush: send the usage recorded so far and await the POST.
//
// The usage transport is deliberately fire-and-forget and debounced, so a POST
// does not go out right after an inference call. This lets a caller force every
// tracked session to emit now, bypassing the debounce and the re-emit window,
// and then await the in-flight send so a short-lived process does not exit
// before it completes.
//
// It is the SDK's public `flushTelemetry()`: the wasm `@JS` export and the
// native `dal_flush_telemetry` symbol both land on `flushAndWait`. Every tracked
// session installs its hook on the first run, so the flush works with or without
// the debug flag below.
//
// One emit per device, not one per session: a model that runs a cascade over
// several sessions (align is coarse + fine) would otherwise report the same
// device's usage once per session.
//
// The debug log and the `__dalFlushTelemetry` global stay opt-in: enabled from JS
// by setting `globalThis.__dalHttpDebug = true`, off native with the
// `DAL_HTTP_DEBUG` environment variable.

#if os(WASI)
import JavaScriptKit
#else
import PlatformSupport
#endif

/// Whether the debug telemetry log and the JS force-flush global are enabled.
public func telemetryDebugEnabled() -> Bool {
    #if os(WASI)
    return JSObject.global.__dalHttpDebug.boolean ?? false
    #else
    return environmentVariable("DAL_HTTP_DEBUG") != nil
    #endif
}

/// One tracked session's flush hook.
///
/// Two closures rather than one: `flush` forces an emit, and a prune must be able
/// to ask whether a session is still there without sending anything on its behalf.
public struct FlushHook: Sendable {
    public let isAlive: @Sendable () -> Bool
    public let flush: @Sendable () async -> Bool

    public init(isAlive: @escaping @Sendable () -> Bool, flush: @escaping @Sendable () async -> Bool) {
        self.isAlive = isAlive
        self.flush = flush
    }
}

/// Tracks live tracked-session flush hooks and in-flight telemetry sends, so a
/// caller can force a send and wait for it to finish.
public actor TelemetryDebug {
    public static let shared = TelemetryDebug()

    /// Past this many hooks, the dead ones are dropped before another is added.
    /// A host that loads a model per request and never flushes would otherwise
    /// hold a closure for every session it has ever opened. Live hooks are never
    /// dropped: losing one is silent metering loss, since nothing else forces
    /// that session's usage out.
    private let maxHooks = 256

    private var flushHooks: [FlushHook] = []
    private var inflight: [Int: Task<Void, Never>] = [:]
    private var nextSendId = 0
    private var claimedDevices: Set<String> = []
    private var flushing = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    /// Register a hook that forces a tracked session to emit immediately. The
    /// hook's `flush` returns false once its session is gone, which drops it.
    public func registerFlushHook(_ hook: FlushHook) {
        pruneHooksIfNeeded()
        flushHooks.append(hook)
    }

    /// The one-closure form, kept so 3.3.0 callers still compile. Such a hook is
    /// never pruned, since it cannot say whether it is still live.
    public func registerFlushHook(_ hook: @escaping @Sendable () async -> Bool) {
        registerFlushHook(FlushHook(isAlive: { true }, flush: hook))
    }

    private func pruneHooksIfNeeded() {
        guard flushHooks.count > maxHooks else { return }
        flushHooks.removeAll { !$0.isAlive() }
    }

    /// Claim this flush pass for one device, so a model that runs a cascade over
    /// several sessions forces that device's turnstile once rather than once per
    /// session. Pass-scoped: the next flush starts with no claims.
    public func claimForcedEmit(device: String) -> Bool {
        claimedDevices.insert(device).inserted
    }

    /// Record an in-flight telemetry send so `flushAndWait` can await it. Returns
    /// the id to hand back to `untrackSend` once it finishes, so the list holds
    /// live sends only. Dropping one by cap or by age would be worse than the
    /// memory: a send still running when its entry goes is a send the next flush
    /// returns without waiting for, which is the exit-before-it-lands failure this
    /// exists to prevent.
    @discardableResult
    public func trackSend(_ task: Task<Void, Never>) -> Int {
        nextSendId += 1
        inflight[nextSendId] = task
        return nextSendId
    }

    /// Forget a send that has finished.
    public func untrackSend(_ id: Int) {
        inflight[id] = nil
    }

    /// Force every tracked session to emit now (bypassing the debounce and the
    /// re-emit window), then await all in-flight telemetry sends. One pass runs
    /// at a time: overlapping passes each start by clearing the claims, so a
    /// device would emit twice in one and not at all in the other.
    public func flushAndWait() async {
        while flushing { await withCheckedContinuation { parked.append($0) } }
        flushing = true
        // Sessions that register while this pass runs append past the mark, so
        // the live prefix cannot drop one that just started.
        let marked = flushHooks.count
        claimedDevices.removeAll()
        var live: [FlushHook] = []
        for hook in flushHooks {
            if await hook.flush() { live.append(hook) }
        }
        flushHooks = live + flushHooks.dropFirst(marked)
        // Let the freshly dispatched detached sends register themselves.
        for _ in 0..<5 { await Task.yield() }
        let pending = Array(inflight.values)
        inflight.removeAll()
        for task in pending { await task.value }
        flushing = false
        let waiting = parked
        parked = []
        for continuation in waiting { continuation.resume() }
    }
}
