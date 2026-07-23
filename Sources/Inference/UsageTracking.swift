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
func tracked(_ session: any InferenceSession) -> any InferenceSession {
    TrackedSession(wrapping: session)
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
    private let storage: UsageStorage
    private let makeDeviceClient: (String) -> UsageClient
    private let debounceNanos: UInt64
    private let maxDevices = 512

    private var clients: [String: UsageClient] = [:]
    private var deviceOrder: [String] = []       // FIFO for eviction
    private var cachedDefaultDevice: String?
    private var pendingFlush: Task<Void, Never>?
    private var started = false
    private var lifecycle: LifecycleObserver?

    init(
        wrapping session: any InferenceSession,
        appId: String? = nil,
        storage: UsageStorage? = nil,
        windowMs: Int64 = dayMs,
        flushAfter: Double = 3,
        clientFactory: ((String) -> UsageClient)? = nil
    ) {
        let resolvedAppId = appId
        let resolvedStorage = storage ?? defaultStorage()
        self.wrapped = session
        self.storage = resolvedStorage
        self.debounceNanos = UInt64(max(0, flushAfter) * 1_000_000_000)
        self.makeDeviceClient = clientFactory ?? { deviceId in
            makeClient(appId: resolvedAppId, deviceId: deviceId, windowMs: windowMs, storage: resolvedStorage)
        }
        // When enabled, register a force-flush hook so a caller can make this
        // session emit immediately (bypassing the debounce + re-emit window).
        if telemetryDebugEnabled() {
            Task { [weak self] in
                await TelemetryDebug.shared.registerFlushHook { [weak self] in
                    await self?.debugForceFlush()
                }
            }
        }
    }

    /// Force an emit for the default device now, ignoring the debounce and the
    /// re-emit window, so the telemetry send actually goes out.
    func debugForceFlush() {
        startIfNeeded()
        let client = clientFor(device(nil))
        client.recordCall()
        client.load()   // forces a turnstile now and flushes -> send
    }

    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor] {
        startIfNeeded()
        let client = clientFor(device(deviceId))
        client.start()
        client.recordCall()
        let result = try await wrapped.run(inputs: inputs, outputs: outputs)
        scheduleFlush()
        return result
    }

    /// Stamp the idle clock and send pending usage for every tracked device (e.g.
    /// on app background / page hide). No-op if inference never ran.
    func suspend() {
        guard started else { return }
        pendingFlush?.cancel()
        pendingFlush = nil
        for client in clients.values { client.suspend() }
    }

    /// Send any pending usage now. Optional — the debounce sends once runs idle.
    func flush() {
        guard started else { return }
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
        lifecycle = LifecycleObserver(onBackground: { [weak self] in
            Task { await self?.suspend() }
        })
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

    private func emitFlush() { for client in clients.values { client.flush() } }

    deinit {
        // Best-effort: only if inference ran. The idle-clock stamp (synchronous
        // storage) lands; the network send is best-effort.
        if started { for client in clients.values { client.suspend() } }
    }
}
