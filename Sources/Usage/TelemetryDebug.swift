// Opt-in support to force telemetry to send immediately and await it.
//
// The usage transport is deliberately fire-and-forget and debounced, so a POST
// does not go out right after an inference call. This lets a caller force every
// tracked session to emit now, bypassing the debounce and the re-emit window,
// and then await the in-flight send so a short-lived process/example does not
// exit before it completes. Useful for tests, tools, and diagnostics.
//
// One emit per device, not one per session: a model that runs a cascade over
// several sessions (align is coarse + fine) would otherwise report the same
// device's usage once per session.
//
// Enabled from JS by setting `globalThis.__dalHttpDebug = true`; off native,
// set the `DAL_HTTP_DEBUG` environment variable. When disabled, the hooks are
// not installed and there is no overhead.

#if os(WASI)
import JavaScriptKit
#elseif os(Android)
import Android          // on Android the Android module *is* libc (getenv et al)
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import CRT
#endif

/// Whether the telemetry force-flush hooks are enabled.
public func telemetryDebugEnabled() -> Bool {
    #if os(WASI)
    return JSObject.global.__dalHttpDebug.boolean ?? false
    #else
    return getenv("DAL_HTTP_DEBUG") != nil
    #endif
}

/// Tracks active tracked-session flush hooks and in-flight telemetry sends so a
/// caller can force a send and wait for it to finish.
public actor TelemetryDebug {
    public static let shared = TelemetryDebug()

    private var flushHooks: [@Sendable () async -> Bool] = []
    private var inflight: [Task<Void, Never>] = []
    private var claimedDevices: Set<String> = []
    private var flushing = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    /// Register a closure that forces a tracked session to emit immediately. The
    /// hook returns false once its session is gone, which drops it.
    public func registerFlushHook(_ hook: @escaping @Sendable () async -> Bool) {
        flushHooks.append(hook)
    }

    /// Claim this flush pass for one device, so a model that runs a cascade over
    /// several sessions forces that device's turnstile once rather than once per
    /// session. Pass-scoped: the next flush starts with no claims.
    public func claimForcedEmit(device: String) -> Bool {
        claimedDevices.insert(device).inserted
    }

    /// Record an in-flight telemetry send so `flushAndWait` can await it.
    public func trackSend(_ task: Task<Void, Never>) {
        inflight.append(task)
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
        var live: [@Sendable () async -> Bool] = []
        for hook in flushHooks {
            if await hook() { live.append(hook) }
        }
        flushHooks = live + flushHooks.dropFirst(marked)
        // Let the freshly dispatched detached sends register themselves.
        for _ in 0..<5 { await Task.yield() }
        let pending = inflight
        inflight = []
        for task in pending { await task.value }
        flushing = false
        let waiting = parked
        parked = []
        for continuation in waiting { continuation.resume() }
    }
}
