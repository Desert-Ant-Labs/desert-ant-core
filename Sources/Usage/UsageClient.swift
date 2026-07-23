// Client state machine for the usage turnstile — a native port of the web SDK's
// `createClient`. Transport- and storage-free by design: the caller injects a
// stable `deviceId`, persisted-state access (`loadState`/`saveState`), a clock,
// and a `send` transport. `makeClient` wires the defaults (system clock + a
// POST transport over PlatformSupport's HTTP client).

/// Re-emit windows. A native/mobile install is persistent, so a device re-emits
/// at most once a DAY. Neither affects billing: MAD is COUNT(DISTINCT deviceId)
/// per month regardless of how often a device re-emits within it.
public let dayMs: Int64 = 24 * 60 * 60 * 1000
/// Session-shaped window (30-min idle timeout) for ephemeral, web-like hosts.
public let webSessionMs: Int64 = 30 * 60 * 1000

/// Persisted per install, across sessions.
public struct UsageState: Sendable, Equatable {
    /// Epoch ms we last emitted or went inactive (0 = never). Gates the next emit.
    public var lastActiveAt: Int64
    /// Calls accrued during throttled sessions, awaiting the next emitted load.
    public var carryCallCount: Int

    public init(lastActiveAt: Int64 = 0, carryCallCount: Int = 0) {
        self.lastActiveAt = lastActiveAt
        self.carryCallCount = carryCallCount
    }
}

/// Transport options. `beacon` requests an unload-safe (synchronous) delivery so
/// a suspending process finishes the request before exiting.
public struct SendOptions: Sendable {
    public var beacon: Bool
    public init(beacon: Bool = false) { self.beacon = beacon }
}

/// Everything the client needs from its host. Mirrors the web SDK's `ClientDeps`.
public struct ClientDeps {
    public var deviceId: String
    public var key: String?
    /// App identity for keyless attribution (bundle id / package name), sent as
    /// `app.id`. Distinct from `key`, which is a publishable API key.
    public var appId: String?
    public var platform: String
    /// Authoritative call count read at emit time; overrides recordCall() when set.
    public var callCount: (() -> Int)?
    /// Default context attached to auto-emitted loads.
    public var context: (() -> [String: String]?)?
    /// Re-emit window (ms): `dayMs` for persistent installs, `webSessionMs` for web-like.
    public var windowMs: Int64
    public var now: () -> Int64
    public var loadState: () -> UsageState
    public var saveState: (UsageState) -> Void
    public var send: (IngestBody, SendOptions) -> Void

    public init(
        deviceId: String,
        key: String? = nil,
        appId: String? = nil,
        platform: String = defaultPlatform,
        callCount: (() -> Int)? = nil,
        context: (() -> [String: String]?)? = nil,
        windowMs: Int64 = dayMs,
        now: @escaping () -> Int64 = systemNowMs,
        loadState: @escaping () -> UsageState,
        saveState: @escaping (UsageState) -> Void,
        send: @escaping (IngestBody, SendOptions) -> Void
    ) {
        self.deviceId = deviceId
        self.key = key
        self.appId = appId
        self.platform = platform
        self.callCount = callCount
        self.context = context
        self.windowMs = windowMs
        self.now = now
        self.loadState = loadState
        self.saveState = saveState
        self.send = send
    }
}

public final class UsageClient {
    private let deps: ClientDeps

    private var sessionCalls = 0      // recordCall() accrued this session, not yet accounted
    private var pending: IngestEvent? // queued turnstile, awaiting first flush
    private var emitted = false       // did we open a turnstile this session?

    public init(_ deps: ClientDeps) { self.deps = deps }

    /// Host calls this once per inference/call to attribute to the turnstile.
    public func recordCall(_ n: Int = 1) {
        if n > 0 { sessionCalls += n }
    }

    /// Evaluate the window and, if a new session/day is due, queue a turnstile.
    /// Call on init and again on reactivation.
    public func start() {
        let st = deps.loadState()
        if deps.now() - st.lastActiveAt < deps.windowMs { return } // still within the same session/day
        // Reserve the slot up front so a second start now won't double-emit.
        deps.saveState(UsageState(lastActiveAt: deps.now(), carryCallCount: st.carryCallCount))
        queue()
    }

    /// Mark the app inactive (stamp the idle clock) and flush via the unload-safe path.
    public func suspend() {
        let st = deps.loadState()
        deps.saveState(UsageState(lastActiveAt: deps.now(), carryCallCount: st.carryCallCount))
        flush(SendOptions(beacon: true))
    }

    /// Force a turnstile now, ignoring the window.
    public func load(context: [String: String]? = nil) {
        let st = deps.loadState()
        deps.saveState(UsageState(lastActiveAt: deps.now(), carryCallCount: st.carryCallCount))
        queue(context: context)
        flush()
    }

    /// Flush any pending event. `beacon: true` uses the unload-safe path.
    public func flush(_ opts: SendOptions = SendOptions()) {
        let st = deps.loadState()

        if var ev = pending {
            // First flush of this session's turnstile: attach carry + session calls.
            pending = nil
            ev.callCount = resolveCount(st.carryCallCount + sessionCalls)
            if deps.callCount == nil {
                deps.saveState(UsageState(lastActiveAt: st.lastActiveAt, carryCallCount: 0))
            }
            sessionCalls = 0
            deps.send(makeBody([ev]), opts)
            return
        }

        if emitted && sessionCalls > 0 {
            // Turnstile already sent; late calls ride a delta load (server sums them).
            let ev = IngestEvent(deviceId: deps.deviceId, callCount: resolveCount(sessionCalls), context: currentContext())
            sessionCalls = 0
            deps.send(makeBody([ev]), opts)
            return
        }

        if !emitted && sessionCalls > 0 && deps.callCount == nil {
            // Throttled session: no turnstile today. Carry the calls to the next emit.
            deps.saveState(UsageState(lastActiveAt: st.lastActiveAt, carryCallCount: st.carryCallCount + sessionCalls))
            sessionCalls = 0
        }
    }

    // Effective count for an emit: provider is authoritative when set, else the
    // accumulated (carry + session) count. Zero is omitted from the wire.
    private func resolveCount(_ accumulated: Int) -> Int? {
        let n = deps.callCount?() ?? accumulated
        return n > 0 ? n : nil
    }

    private func currentContext() -> [String: String]? {
        deps.context.flatMap { $0() }
    }

    private func queue(context: [String: String]? = nil) {
        pending = IngestEvent(deviceId: deps.deviceId, context: context ?? currentContext())
        emitted = true
    }

    private func makeBody(_ events: [IngestEvent]) -> IngestBody {
        IngestBody(platform: deps.platform, key: deps.key, app: deps.appId.map(AppInfo.init(id:)), sdk: SDKInfo(), sentAt: iso8601(epochMs: deps.now()), events: events)
    }
}
