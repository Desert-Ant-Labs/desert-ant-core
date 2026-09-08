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

    /// Debounce before flushing, matching core's `TrackedSession`.
    private static let flushAfterSeconds: UInt64 = 3

    init(client: UsageClient) {
        self.client = client
        client.start()
    }

    /// One detection. Records the call and arranges a single flush for the burst.
    func record() {
        client.recordCall()
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
}

/// The turnstile for a new `Tongue`, or `nil` when usage is switched off. Keeps
/// `import Usage` to this file, so the pipeline stays free of it.
func makeTurnstile() -> UsageTurnstile? {
    usageDisabled() ? nil : UsageTurnstile(client: makeClient())
}

// `usageDisabled()` is core's, in `Usage` (this file already imports it). Tongue
// used to carry its own copy; they never differed, so it is the shared one now.
