// The usage turnstile, wired directly.
//
// emo, redact and shapes never write this: they depend on desert-ant-core's
// `Inference`, which depends on `Usage` and wraps every session it builds in a
// `TrackedSession`, so there is no untracked path. This model has no inference
// runtime — a detection is arithmetic, not a Core ML or LiteRT session — so there
// is no session factory to hook, and the client is opened here instead.
//
// Same guarantees, reached differently: one turnstile per `Tongue`, opened on
// construction, a call recorded per `detect`, and a debounced flush that coalesces
// a burst of keystrokes into one send. The state machine, storage keys and wire
// format all come from core's `Usage`, so a device counts identically however it
// reached the endpoint.
//
// The Kotlin and JavaScript SDKs cannot share this file — they are direct ports
// with no Swift underneath, unlike emo's JNI and native bridges — so each carries
// its own port of the same state machine. docs/USAGE.md is the reference.

import Usage

/// Owns the turnstile for one `Tongue`.
///
/// An actor rather than a lock: `UsageClient` is not `Sendable`, and the platforms
/// this package cross-compiles to do not share one mutex type (no Foundation on
/// Android by design, no threads at all on WASI). Core's `TrackedSession` is an
/// actor for the same reason.
actor UsageTurnstile {
    private let client: UsageClient
    private var flushScheduled = false
    private var registeredFlushHook = false
    /// Where the flush hook registers. A test passes its own, so its flush pass
    /// does not force every other suite's live sessions to emit mid-test.
    private let telemetry: TelemetryDebug

    /// Debounce before flushing, matching core's `TrackedSession`.
    private static let flushAfterSeconds: UInt64 = 3

    init(client: UsageClient, telemetry: TelemetryDebug = .shared) {
        self.client = client
        self.telemetry = telemetry
        client.start()
    }

    /// One detection. Records the call and arranges a single flush for the burst.
    func record() async {
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
        client.flush()
    }

    /// Emit now, ignoring the debounce and the re-emit window: this turnstile's
    /// part of `flushAndWait()`. Claims the device the way core's
    /// `TrackedSession` does, so a device shared with another session posts once.
    func forceFlush() async {
        guard client.hasUsage else { return }
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

/// The turnstile for a new `Tongue`, or `nil` when usage is switched off. Keeps
/// `import Usage` to this file, so the pipeline stays free of it.
func makeTurnstile() -> UsageTurnstile? {
    usageDisabled() ? nil : UsageTurnstile(client: makeClient())
}

// `usageDisabled()` is core's, in `Usage` (this file already imports it). Tongue
// used to carry its own copy; they never differed, so it is the shared one now.
