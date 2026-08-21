// Per-call inference context, propagated through Swift structured concurrency.
//
// In a multi-tenant host (e.g. a single Node process serving many users) the
// end-user device id must be bound to the individual inference call, not read
// from a process-wide global that concurrent calls would race on. A task-local
// carries it down the `await` chain of exactly that call's task tree, so
// overlapping calls stay isolated — and no SDK has to thread `deviceId` through
// its public API. The host binds it once at its entry point:
//
//     try await InferenceContext.$deviceId.withValue(id) {
//         try await emo.suggestions(for: text)
//     }

// pthread on the threaded platforms (matches Lifecycle/LiteRTSession); WASI is
// single-threaded, so its call group needs no lock (see below).
#if os(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

public enum InferenceContext {
    /// The end-user device id for the current call, or `nil` for the default
    /// device. Read by `InferenceSession.run(inputs:outputs:)`.
    @TaskLocal public static var deviceId: String?

    /// The active call group, if the current call is running inside
    /// `withCallGroup`. Read by the usage-tracking session to coalesce the runs
    /// it wraps into a single billed call. `nil` means each run counts on its own.
    @TaskLocal public static var callGroup: InferenceCallGroup?

    /// Coalesce every inference run made inside `body` into a single tracked
    /// usage call (per device). Use it when one logical operation performs
    /// several `run`s — e.g. a multi-stage or autoregressive model — but should
    /// bill as one call:
    ///
    ///     try await InferenceContext.withCallGroup {
    ///         let a = try await session.run(...)   // records the call
    ///         let b = try await session.run(...)   // same group -> not counted again
    ///     }
    ///
    /// Runs outside any group count individually, as before. Nesting reuses the
    /// enclosing group, so wrapping an already-grouped operation is a no-op.
    /// Combine with `$deviceId` freely; the two task-locals are independent.
    public static func withCallGroup<T>(
        _ body: () async throws -> T
    ) async rethrows -> T {
        // Already inside a group: reuse it so nested wraps still bill as one.
        if callGroup != nil { return try await body() }
        return try await $callGroup.withValue(InferenceCallGroup(), operation: body)
    }

    /// Bind the process-global call group named `id` for `body` (created on first
    /// use), so every run inside bills as one call. A `nil` id runs ungrouped.
    ///
    /// This is the reuse path for hosts whose calls cross a boundary that does
    /// not preserve a task-local — chiefly a native C ABI invoked once per host
    /// call (the JS/koffi SDKs): the host passes a stable id per logical
    /// operation and releases it with `endCallGroup(_:)` (or the
    /// `dal_call_group_end` C entry point) when done. Every SDK reuses this
    /// registry, so none reimplements the grouping bookkeeping.
    public static func withCallGroup<T>(
        id: String?,
        _ body: () async throws -> T
    ) async rethrows -> T {
        guard let id else { return try await body() }
        return try await $callGroup.withValue(CallGroupRegistry.shared.group(id), operation: body)
    }

    /// Release the process-global call group named `id`. Safe to call for an
    /// unknown id (no-op). Pairs with `withCallGroup(id:)`.
    public static func endCallGroup(_ id: String) {
        CallGroupRegistry.shared.end(id)
    }
}

/// Process-global registry of call groups by id, so several host calls (each a
/// separate C-ABI invocation) that share an id coalesce into one billed usage
/// call. Shared by every SDK; created lazily per id, dropped by `endCallGroup`.
#if os(WASI)
final class CallGroupRegistry: @unchecked Sendable {
    static let shared = CallGroupRegistry()
    private var groups: [String: InferenceCallGroup] = [:]   // single-threaded: no lock

    func group(_ id: String) -> InferenceCallGroup {
        if let existing = groups[id] { return existing }
        let group = InferenceCallGroup(); groups[id] = group; return group
    }
    func end(_ id: String) { groups[id] = nil }
}
#else
final class CallGroupRegistry: @unchecked Sendable {
    static let shared = CallGroupRegistry()
    private let mutex = PlatformMutex()
    private var groups: [String: InferenceCallGroup] = [:]

    func group(_ id: String) -> InferenceCallGroup {
        mutex.lock(); defer { mutex.unlock() }
        if let existing = groups[id] { return existing }
        let group = InferenceCallGroup(); groups[id] = group; return group
    }
    func end(_ id: String) {
        mutex.lock(); defer { mutex.unlock() }
        groups[id] = nil
    }
}
#endif

// Generic C entry point to release a call group, exported by every SDK's native
// core (they all link Inference). The JS/koffi hosts bind this one symbol rather
// than each SDK shipping its own `*_group_end`. Native only (no C ABI on WASI).
#if !os(WASI)
@_cdecl("dal_call_group_end")
public func dal_call_group_end(_ id: UnsafePointer<CChar>?) {
    guard let id else { return }
    InferenceContext.endCallGroup(String(cString: id))
}
#endif

/// Identity for a set of inference runs that should bill as a single usage call.
/// It records which usage clients have already been attributed within the group,
/// so a second run to the same device does not record another call. Created by
/// `InferenceContext.withCallGroup`; opaque to callers.
#if os(WASI)
public final class InferenceCallGroup: @unchecked Sendable {
    private var counted: Set<ObjectIdentifier> = []   // single-threaded: no lock
    public init() {}

    /// Mark `key` counted for this group; returns true only the first time.
    func markCounted(_ key: ObjectIdentifier) -> Bool {
        counted.insert(key).inserted
    }
}
#else
public final class InferenceCallGroup: @unchecked Sendable {
    private let mutex = PlatformMutex()
    private var counted: Set<ObjectIdentifier> = []

    public init() {}

    /// Mark `key` counted for this group; returns true only the first time.
    func markCounted(_ key: ObjectIdentifier) -> Bool {
        mutex.lock(); defer { mutex.unlock() }
        return counted.insert(key).inserted
    }
}
#endif
