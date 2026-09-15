#if canImport(CoreML)
// The usage turnstile, wired directly.
//
// emo, redact and clear never write this: they reach Core ML through
// `Inference`, whose session factory wraps everything it builds in a
// `TrackedSession`, so there is no untracked path. This model does not use that
// factory - Catalog.swift explains why, and it costs roughly 127x on load and a
// third of decode throughput to go back - so until now it was the one SDK that
// reported nothing at all. The client is opened here instead, exactly as
// `Tongue` does for the same reason.
//
// Same guarantees, reached differently: one turnstile per `Voz`, opened when the
// model loads, a call recorded per transcription, and a debounced flush that
// coalesces a burst into one send. The state machine, storage keys and wire
// format all come from core's `Usage`, so a device counts identically however it
// reached the endpoint.
//
// A call is one transcription, not one `predict`. Ten minutes of speech is about
// 370 dispatches across three Core ML programs, and billing those individually
// would count one user-facing operation hundreds of times, at a rate that varies
// with the length of the audio. Core has the same rule for the same reason:
// `InferenceContext.callGroup` makes a multi-run operation bill as one. This is
// that rule, reached without the session.

import DesertAnt

/// Owns the turnstile for one `Voz`.
///
/// An actor rather than a lock, because `UsageClient` is not `Sendable`: its
/// counters are unsynchronized and only this actor touches them. Core's
/// `TrackedSession` is an actor for the same reason.
actor UsageTurnstile {
    private let client: UsageClient
    private var flushScheduled = false

    /// Debounce before flushing, matching core's `TrackedSession`.
    private static let flushAfterSeconds: UInt64 = 3

    init(client: UsageClient) {
        self.client = client
        client.start()
    }

    /// One transcription. Records the call and arranges a single flush for the
    /// burst, so a caller transcribing a folder sends once rather than per file.
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

/// The turnstile for a new `Voz`, or `nil` when usage is switched off. Keeps the
/// usage surface to this file, so the pipeline stays free of it.
///
/// `VozModel.sdkInfo` is the catalog's own identity, so this model's calls
/// arrive under its own name and version rather than the package's.
func makeTurnstile() -> UsageTurnstile? {
    usageDisabled() ? nil : UsageTurnstile(client: makeClient(sdk: VozModel.sdkInfo))
}
#endif
