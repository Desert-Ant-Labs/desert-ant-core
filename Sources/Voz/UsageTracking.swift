#if canImport(CoreML)
// The usage turnstile, wired directly. Other models get usage from `Inference`,
// which wraps every session in a `TrackedSession`; this model drives Core ML
// directly (Catalog.swift explains why; the factory costs roughly 127x on load
// and a third of decode throughput), so the client is opened here, as `Tongue`
// does. The state machine, storage keys and wire format come from core's `Usage`.
//
// A call is one transcription, not one `predict`. Ten minutes of speech is about
// 370 dispatches across three Core ML programs, and billing those individually
// would count one user-facing operation hundreds of times. This is the rule
// `InferenceContext.callGroup` applies, reached without the session.

import DesertAnt

/// Owns the turnstile for one `Voz`.
///
/// An actor rather than a lock, because `UsageClient` is not `Sendable`: its
/// counters are unsynchronized and only this actor touches them. Core's
/// `TrackedSession` is an actor for the same reason.
actor UsageTurnstile {
    /// Built on the first recorded call, so a turnstile that never records touches no store and mints no device id.
    private var client: UsageClient?
    private let buildClient: () -> UsageClient
    private var flushScheduled = false
    private var registeredFlushHook = false
    /// Where the flush hook registers. A test passes its own, so its flush pass
    /// does not force every other suite's live sessions to emit mid-test.
    private let telemetry: TelemetryDebug

    /// Debounce before flushing, matching core's `TrackedSession`.
    private static let flushAfterSeconds: UInt64 = 3

    init(
        client: @autoclosure @escaping () -> UsageClient,
        telemetry: TelemetryDebug = .shared
    ) {
        self.buildClient = client
        self.telemetry = telemetry
    }

    /// The client, built the first time it is needed.
    private func openClient() -> UsageClient {
        if let client { return client }
        let opened = buildClient()
        client = opened
        return opened
    }

    /// One transcription. Records the call and arranges a single flush for the
    /// burst, so a caller transcribing a folder sends once rather than per file.
    func record() async {
        // `start()` on every call, as `TrackedSession` does per run: the first
        // call of a new UTC day must open a turnstile however recently the app
        // was active, and it is a no-op otherwise inside the window.
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

    private func flushNow() {
        flushScheduled = false
        client?.flush()
    }

    /// Emit now, ignoring the debounce and the re-emit window: this turnstile's
    /// part of `flushAndWait()`. Claims the device the way core's
    /// `TrackedSession` does, so a device shared with another session posts once.
    func forceFlush() async {
        guard let client, client.hasUsage else { return }
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

/// The turnstile for a new `Voz`. Keeps the usage surface to this file, so the
/// pipeline stays free of it. It opens no client until a call is recorded.
///
/// `VozModel.sdkInfo` is the catalog's own identity, so this model's calls
/// arrive under its own name and version rather than the package's.
func makeTurnstile() -> UsageTurnstile {
    UsageTurnstile(client: makeClient(sdk: VozModel.sdkInfo))
}
#endif
