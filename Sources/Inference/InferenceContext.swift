// Per-call inference context, propagated through Swift structured concurrency.
//
// In a multi-tenant host (e.g. a single Node process serving many users) the
// end-user device id must be bound to the individual inference call, not read
// from a process-wide global that concurrent calls would race on. A task-local
// carries it down the `await` chain of exactly that call's task tree, so
// overlapping calls stay isolated, and no SDK has to thread `deviceId` through
// its public API. The host binds it once at its entry point:
//
//     try await InferenceContext.$deviceId.withValue(id) {
//         try await emo.suggestions(for: text)
//     }
//
// Licensing counts the install and does not read the device id yet.

public enum InferenceContext {
    /// The end-user device id for the current call, or `nil` for the default
    /// device. Read by `InferenceSession.run(inputs:outputs:)`.
    @TaskLocal public static var deviceId: String?

    @available(*, deprecated, message: "Has no effect. Licensing counts installs, not calls.")
    @TaskLocal public static var callGroup: InferenceCallGroup?

    @available(*, deprecated, message: "Has no effect. Licensing counts installs, not calls.")
    public static func withCallGroup<T>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await body()
    }

    @available(*, deprecated, message: "Has no effect. Licensing counts installs, not calls.")
    public static func withCallGroup<T>(
        id: String?,
        _ body: () async throws -> T
    ) async rethrows -> T {
        try await body()
    }

    @available(*, deprecated, message: "Has no effect. Licensing counts installs, not calls.")
    public static func endCallGroup(_ id: String) {}
}

// An older @desert-ant-labs/core binds this symbol at load, so it stays, as a no-op.
#if !os(WASI)
@_cdecl("dal_call_group_end")
public func dal_call_group_end(_ id: UnsafePointer<CChar>?) {}
#endif

@available(*, deprecated, message: "Has no effect. Licensing counts installs, not calls.")
public final class InferenceCallGroup: Sendable {
    public init() {}
}
