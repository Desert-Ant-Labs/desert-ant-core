#if canImport(Darwin)
import Dispatch

/// A thread for the decode half of a group, so it does not take one of the
/// cooperative pool's.
///
/// This matters more than it looks. Both halves of a group are synchronous once
/// they reach Core ML, so a decode left on the cooperative pool sits behind an
/// encoder that is blocking one of the few threads it has: measured 192 RTFx
/// against 207 on an M1, most of the overlap gone.
///
/// A custom `SerialExecutor` rather than `Task.detached(executorPreference:)`,
/// which is the obvious spelling and needs macOS 15.4 - above this package's
/// floor, so every system below it would silently fall back to the pool and
/// keep that loss. `SerialExecutor` has been available since the concurrency
/// runtime shipped, so one path covers every supported OS.
///
/// One queue per pipeline, not one shared: two transcriptions running at once
/// must not queue their decodes behind each other.
actor DecodeWorker {
    private final class QueueExecutor: SerialExecutor {
        private let queue = DispatchQueue(label: "voz.decode", qos: .userInitiated)

        func enqueue(_ job: UnownedJob) {
            let executor = asUnownedSerialExecutor()
            queue.async { job.runSynchronously(on: executor) }
        }
    }

    private nonisolated let executor = QueueExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    func run(_ body: @Sendable (isolated DecodeWorker) async -> Void) async {
        await body(self)
    }
}
#endif
