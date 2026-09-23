// Usage tracking, folded into inference so there is no untracked path: the
// session factory wraps every session it builds with `TrackedSession`, and the
// concrete backends are non-public, so an SDK can only obtain a tracked session.
//
// `TrackedSession` opens the turnstile once, records a call on every `run`, and
// flushes on a short debounce (coalescing bursts into one send).

import Usage

/// Wrap a session so usage is recorded and sent automatically. Called by the
/// session factory; the derived app identity + native storage come from
/// `makeClient`.
///
/// Wrapped even while usage is off: the switch is a consent flag a host may
/// clear after load, so `TrackedSession` reads it per run instead.
func tracked(_ session: any InferenceSession, sdk: SDKInfo = SDKInfo()) -> any InferenceSession {
    TrackedSession(wrapping: session, sdk: sdk, disabled: usageDisabled)
}

/// An `InferenceSession` that records a usage call per `run` and batches sends.
///
/// Multi-tenant aware: a `run(deviceId:)` attributes to a specific end-user
/// device (a server serving many users), each with its own turnstile; `nil`
/// uses the default device (persisted app id, or a host-provided one). Per-device
/// clients are cached (bounded, FIFO-evicted) so state accumulates across runs.
///
/// An actor for data-race safety around the (non-Sendable) clients, but it does
/// not serialize inference: each `run` records (fast), then releases the actor
/// while awaiting the wrapped session, so concurrent runs still run concurrently.
actor TrackedSession: InferenceSession {
    private let wrapped: any InferenceSession

    /// Forwarded, `nonisolated` so it satisfies the synchronous protocol requirement.
    ///
    /// Without this the wrapper silently inherits the protocol's `nil` default and every caller
    /// falls back to its own constant, with no compile error or warning: the clips scorer would
    /// size a 256-wide graph's buffers at the fallback 128, and Core ML rejects the batch.
    nonisolated func inputWidth(_ name: String) -> Int? { wrapped.inputWidth(name) }

    /// Forwarded for the same reason `inputWidth` is: a wrapper that drops this
    /// inherits the protocol's "no", and since the factory hands out nothing
    /// but wrapped sessions, every caller would quietly run one at a time.
    nonisolated var runsConcurrently: Bool { wrapped.runsConcurrently }

    private let storage: UsageStorage
    private let makeDeviceClient: (String) -> UsageClient
    /// The opt-out, read on every run. `tracked` passes `usageDisabled`; the
    /// default is for tests, whose suites run with the switch on.
    private let disabled: @Sendable () -> Bool
    private let debounceNanos: UInt64
    private let maxDevices = 512

    // `nonisolated(unsafe)` so the `deinit` below can flush these. A deinit is
    // nonisolated and `UsageClient` is deliberately not Sendable (unsynchronized
    // counters only this actor touches), which the Swift 6 language mode rejects.
    // `isolated deinit` (SE-0371) is the feature for this but needs macOS 15.4 /
    // iOS 18.4, far above this package's floor. The unchecked access is sound
    // rather than asserted: a deinit runs only once the last reference is gone,
    // and a task executing on an actor holds one, so no actor work can be in
    // flight to race with it.
    private nonisolated(unsafe) var clients: [String: UsageClient] = [:]
    private var deviceOrder: [String] = []       // FIFO for eviction
    private var cachedDefaultDevice: String?
    private var pendingFlush: Task<Void, Never>?
    private var started = false
    private var registeredFlushHook = false
    private var lifecycle: LifecycleObserver?

    init(
        wrapping session: any InferenceSession,
        appId: String? = nil,
        sdk: SDKInfo = SDKInfo(),
        storage: UsageStorage? = nil,
        windowMs: Int64 = dayMs,
        flushAfter: Double = 3,
        clientFactory: ((String) -> UsageClient)? = nil,
        disabled: @escaping @Sendable () -> Bool = { false }
    ) {
        let resolvedAppId = appId
        let resolvedStorage = storage ?? defaultStorage()
        self.wrapped = session
        self.disabled = disabled
        self.storage = resolvedStorage
        self.debounceNanos = UInt64(max(0, flushAfter) * 1_000_000_000)
        self.makeDeviceClient = clientFactory ?? { deviceId in
            makeClient(appId: resolvedAppId, sdk: sdk, deviceId: deviceId, windowMs: windowMs, storage: resolvedStorage)
        }
    }

    /// Force an emit per device now, ignoring the debounce and the re-emit window,
    /// so the telemetry send actually goes out. One pass claims a device, so a
    /// cascade running several sessions over it posts that device's usage once
    /// rather than once per session. The session that loses the claim carries its
    /// calls to storage instead of posting, so they ride the next emit.
    func forceFlush() async {
        if disabled() { return }
        for (deviceId, client) in clients where client.hasUsage {
            guard await TelemetryDebug.shared.claimForcedEmit(device: deviceId) else {
                client.carryUnsent()
                continue
            }
            client.load()   // forces a turnstile now and flushes -> send
        }
    }

    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor] {
        // Off means the bare run: no client, no device id, no store write, no
        // debounce task, and no fire-and-forget send that could still be in
        // flight when a short-lived process exits (which is what raced the node
        // test runner's teardown into a SIGSEGV). Read per run, so a consent
        // given after load reports from the next run on. Every flush reads it
        // too: calls recorded before it was set are held, neither stored nor
        // sent, until it is cleared.
        if disabled() { return try await wrapped.run(inputs: inputs, outputs: outputs) }
        startIfNeeded()
        await registerFlushHookIfNeeded()
        let resolvedDevice = device(deviceId)
        let client = clientFor(resolvedDevice)
        client.start()
        // Outside a group every run counts; inside one, only the first per device.
        // The task-local propagates into this actor method on the caller's task.
        if InferenceContext.callGroup?.markCounted(resolvedDevice) ?? true {
            client.recordCall()
        }
        let result = try await wrapped.run(inputs: inputs, outputs: outputs)
        scheduleFlush()
        return result
    }

    /// Stamp the idle clock and send pending usage for every tracked device (e.g.
    /// on app background / page hide). No-op if inference never ran.
    func suspend() {
        guard started, !disabled() else { return }
        pendingFlush?.cancel()
        pendingFlush = nil
        for client in clients.values { client.suspend() }
    }

    /// Send any pending usage now. Optional: the debounce sends once runs idle.
    func flush() {
        guard started, !disabled() else { return }
        pendingFlush?.cancel()
        pendingFlush = nil
        for client in clients.values { client.flush() }
    }

    // The device for a run: an explicit id (multi-tenant), else a host-provided
    // one, else the persisted app device (cached to avoid a storage read per run).
    private func device(_ explicit: String?) -> String {
        if let explicit { return explicit }
        if let host = hostProvidedDeviceId() { return host }
        if let cached = cachedDefaultDevice { return cached }
        let id = storage.persistentDeviceId()
        cachedDefaultDevice = id
        return id
    }

    private func clientFor(_ deviceId: String) -> UsageClient {
        if let existing = clients[deviceId] { return existing }
        let client = makeDeviceClient(deviceId)
        clients[deviceId] = client
        deviceOrder.append(deviceId)
        if clients.count > maxDevices {
            let oldest = deviceOrder.removeFirst()
            clients[oldest]?.flush()   // send pending before evicting; state persists in storage
            clients[oldest] = nil
        }
        return client
    }

    // Install lifecycle hooks on the first run only.
    private func startIfNeeded() {
        guard !started else { return }
        started = true
        // Bind `self` before the Task rather than writing `self?.suspend()`
        // inside it: the weak capture is a var, and referencing a captured var
        // from concurrently-executing code is an error on the Swift versions the
        // published darwin native is built with. Holding it for the duration of
        // the suspend also lets the flush finish.
        lifecycle = LifecycleObserver(onBackground: { [weak self] in
            guard let self else { return }
            Task { await self.suspend() }
        })
    }

    /// Install the force-flush hook on the first run. Not in `init`: registering
    /// from a detached Task there would race the flush, so an immediate
    /// `flushTelemetry()` after an inference could find no hook and send nothing.
    /// Awaiting it here means a flush after any awaited run always sees the
    /// session. A session that never ran has nothing to send.
    private func registerFlushHookIfNeeded() async {
        guard !registeredFlushHook else { return }
        registeredFlushHook = true
        await TelemetryDebug.shared.registerFlushHook(
            FlushHook(
                isAlive: { [weak self] in self != nil },
                flush: { [weak self] in
                    guard let self else { return false }
                    await self.forceFlush()
                    return true
                }
            )
        )
    }

    private func scheduleFlush() {
        pendingFlush?.cancel()
        let delay = debounceNanos
        pendingFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            if Task.isCancelled { return }
            await self?.emitFlush()
        }
    }

    private func emitFlush() {
        if disabled() { return }
        for client in clients.values { client.flush() }
    }

    deinit {
        // Best-effort: only if inference ran. The idle-clock stamp (synchronous
        // storage) lands; the network send is best-effort.
        if started && !disabled() { for client in clients.values { client.suspend() } }
    }
}
