#if !os(WASI)
import Dispatch
#endif

final class InflightWork: @unchecked Sendable {
    static let shared = InflightWork()

    private var tasks: [Int: Task<Void, Never>] = [:]
    private var nextId = 0

    func add(_ task: Task<Void, Never>) -> Int {
        withLock {
            nextId += 1
            tasks[nextId] = task
            return nextId
        }
    }

    var registeredTotal: Int { withLock { nextId } }

    func remove(_ id: Int) {
        withLock { tasks[id] = nil }
    }

    func snapshot() -> [(id: Int, task: Task<Void, Never>)] {
        withLock { tasks.map { (id: $0.key, task: $0.value) } }
    }

    var count: Int { withLock { tasks.count } }

#if os(WASI)
    private func withLock<T>(_ body: () -> T) -> T { body() }
#else
    private let lock = DispatchSemaphore(value: 1)

    private func withLock<T>(_ body: () -> T) -> T {
        lock.wait()
        defer { lock.signal() }
        return body()
    }
#endif
}

// Registered before this returns, so a flush right after a model load waits for the work.
func dispatchTracked(
    into registry: InflightWork = .shared,
    _ work: @escaping @Sendable () async -> Void
) {
    let task = Task.detached(priority: .utility) { await work() }
    let id = registry.add(task)
    Task {
        await task.value
        registry.remove(id)
    }
}

// Backs `flushTelemetry()`: waits for the license requests in flight, not for a retry still waiting out its delay.
public actor TelemetryDebug {
    public static let shared = TelemetryDebug()

    private let work: InflightWork

    init(work: InflightWork = .shared) {
        self.work = work
    }

    public func flushAndWait() async {
        var awaited: Set<Int> = []
        while true {
            let pending = work.snapshot().filter { !awaited.contains($0.id) }
            if pending.isEmpty { return }
            for entry in pending {
                await entry.task.value
                awaited.insert(entry.id)
            }
        }
    }
}
