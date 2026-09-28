// Tracked sessions by the host handle whose runs used them (`InferenceContext.owner`).

/// Lets a host that releases a handle suspend that handle's sessions, and no others, before the release.
public actor SessionOwners {
    public static let shared = SessionOwners()

    private final class WeakSession {
        weak var session: TrackedSession?
        init(_ session: TrackedSession) { self.session = session }
    }

    private var sessions: [UInt: [WeakSession]] = [:]

    func add(_ session: TrackedSession, owner: UInt) {
        // Dead boxes go first, so an entry left by a run after its handle's release cannot outlive the sessions it names.
        sessions = sessions.compactMapValues { boxes in
            let live = boxes.filter { $0.session != nil }
            return live.isEmpty ? nil : live
        }
        sessions[owner, default: []].append(WeakSession(session))
    }

    /// Suspends `owner`'s sessions in the background, then runs `release`; never blocks the caller, and the exit wait covers it.
    public nonisolated func suspendAll(owner: UInt, thenRelease release: @escaping @Sendable () -> Void) {
        dispatchUsageWork {
            await self.suspendAll(owner: owner)
            release()
        }
    }

    /// Suspends every live session `owner`'s runs used, which sends or carries their pending usage within the re-emit window.
    public func suspendAll(owner: UInt) async {
        for box in sessions.removeValue(forKey: owner) ?? [] {
            await box.session?.suspend()
        }
    }
}
