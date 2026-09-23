// The usage turnstile, wired directly. Other models get usage from `Inference`,
// which wraps every session in a `TrackedSession`; Tongue has no inference
// session to hook (a detection is arithmetic), so the client is opened here.
//
// Same guarantees: one turnstile per `Tongue`, opened on the first detection, a
// call recorded per `detect`, and a debounced flush that coalesces a burst of
// keystrokes into one send. The state machine, storage keys and wire format come
// from core's `Usage`.
//
// The Kotlin and JavaScript SDKs are direct ports with no Swift underneath, so
// each carries its own port of the same state machine.
// packages/tongue-node/USAGE.md is the reference.

import Usage

/// Owns the turnstile for one `Tongue`.
///
/// An actor rather than a lock: `UsageClient` is not `Sendable`, and the platforms
/// this package cross-compiles to do not share one mutex type (no Foundation on
/// Android by design, no threads at all on WASI). Core's `TrackedSession` is an
/// actor for the same reason.
actor UsageTurnstile {
    /// Built on the first call recorded with usage on, so a turnstile made
    /// while it is off touches no store and mints no device id.
    private var client: UsageClient?
    private let buildClient: () -> UsageClient
    /// The opt-out, read per call. `makeTurnstile` passes `usageDisabled`; the
    /// default is for tests, whose suites run with the switch on.
    private let disabled: @Sendable () -> Bool
    private var flushScheduled = false
    private var registeredFlushHook = false
    /// Where the flush hook registers. A test passes its own, so its flush pass
    /// does not force every other suite's live sessions to emit mid-test.
    private let telemetry: TelemetryDebug

    /// Debounce before flushing, matching core's `TrackedSession`.
    private static let flushAfterSeconds: UInt64 = 3

    init(
        client: @autoclosure @escaping () -> UsageClient,
        telemetry: TelemetryDebug = .shared,
        disabled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.buildClient = client
        self.telemetry = telemetry
        self.disabled = disabled
    }

    /// The client, built the first time it is needed.
    private func openClient() -> UsageClient {
        if let client { return client }
        let opened = buildClient()
        client = opened
        return opened
    }

    /// One detection. Records the call and arranges a single flush for the burst.
    func record() async {
        // Read per call: a consent flow sets or clears it after load.
        if disabled() { return }
        // `start()` on every call, as `TrackedSession` does per run: the first
        // call of a new UTC day must open a turnstile however recently the app
        // was active, it is a no-op otherwise inside the window, and a switch set
        // between the check above and the client's own would otherwise leave a
        // start skipped for good.
        let client = openClient()
        client.start()
        client.recordCall()
        await registerFlushHookIfNeeded()
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.flushAfterSeconds * 1_000_000_000)
            await self?.flushNow()
        }
    }

    /// `record()` for a caller that cannot await it. The pending call is
    /// registered before this returns, so a flush right after still counts it.
    nonisolated func recordInBackground() {
        // Checked here as well, so a switched-off keystroke starts no task.
        if disabled() { return }
        telemetry.recordInBackground { await self.record() }
    }

    /// Held while usage is switched off: the calls stay unsent and unstored,
    /// and the next call recorded with it cleared schedules a flush again.
    private func flushNow() {
        flushScheduled = false
        if disabled() { return }
        client?.flush()
    }

    /// Emit now, ignoring the debounce and the re-emit window: this turnstile's
    /// part of `flushAndWait()`. Claims the device the way core's
    /// `TrackedSession` does, so a device shared with another session posts once.
    func forceFlush() async {
        guard let client, !disabled(), client.hasUsage else { return }
        guard await telemetry.claimForcedEmit(device: client.deviceId) else {
            client.carryUnsent()
            return
        }
        client.load()
    }

    /// Install the force-flush hook on the first recorded call, as core's
    /// `TrackedSession` does on its first run. Without it `flushAndWait()` never
    /// reaches this turnstile, and its usage waits out the debounce instead.
    private func registerFlushHookIfNeeded() async {
        guard !registeredFlushHook else { return }
        registeredFlushHook = true
        await telemetry.registerFlushHook(
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
}

/// The turnstile for a new `Tongue`. Keeps `import Usage` to this file, so the
/// pipeline stays free of it. Built even while usage is switched off, since the
/// switch may be cleared later; it opens no client until a call is recorded
/// with usage on.
func makeTurnstile() -> UsageTurnstile {
    UsageTurnstile(client: makeTongueClient(), disabled: usageDisabled)
}

/// The client every `Tongue` turnstile is built on. `TongueModel.sdkInfo` is the
/// catalog's own identity, so detections arrive under this model's name and
/// version rather than the package's. `storage`, `send` and `disabled` are for tests.
func makeTongueClient(
    storage: UsageStorage? = nil,
    send: ((IngestBody, SendOptions) -> Void)? = nil,
    disabled: @escaping () -> Bool = usageDisabled
) -> UsageClient {
    makeClient(sdk: TongueModel.sdkInfo, storage: storage, send: send, disabled: disabled)
}
