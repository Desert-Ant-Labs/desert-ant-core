// Opt-in support to force telemetry to send immediately and await it.
//
// The usage transport is deliberately fire-and-forget and debounced, so a POST
// does not go out right after an inference call. This lets a caller force every
// tracked session to emit now, bypassing the debounce and the re-emit window,
// and then await the in-flight send so a short-lived process/example does not
// exit before it completes. Useful for tests, tools, and diagnostics.
//
// Enabled from JS by setting `globalThis.__dalHttpDebug = true`; off native,
// set the `DAL_HTTP_DEBUG` environment variable. When disabled, the hooks are
// not installed and there is no overhead.

#if os(WASI)
import JavaScriptKit
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
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

    private var flushHooks: [@Sendable () async -> Void] = []
    private var inflight: [Task<Void, Never>] = []

    /// Register a closure that forces a tracked session to emit immediately.
    public func registerFlushHook(_ hook: @escaping @Sendable () async -> Void) {
        flushHooks.append(hook)
    }

    /// Record an in-flight telemetry send so `flushAndWait` can await it.
    public func trackSend(_ task: Task<Void, Never>) {
        inflight.append(task)
    }

    /// Force every tracked session to emit now (bypassing the debounce and the
    /// re-emit window), then await all in-flight telemetry sends.
    public func flushAndWait() async {
        for hook in flushHooks { await hook() }
        // Let the freshly dispatched detached sends register themselves.
        for _ in 0..<5 { await Task.yield() }
        let pending = inflight
        inflight = []
        for task in pending { await task.value }
    }
}
