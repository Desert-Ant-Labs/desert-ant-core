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

// Backs `flushLicenses()`: waits for the requests in flight and sends the queued device licenses. No device request starts after 10 seconds.
public actor LicenseFlush {
    public static let shared = LicenseFlush()

    private let work: InflightWork
    private let client: DeviceLicenseClient
    private let now: @Sendable () -> Int64

    init(
        work: InflightWork = .shared, client: DeviceLicenseClient = .shared,
        now: @escaping @Sendable () -> Int64 = systemNowMs
    ) {
        self.work = work
        self.client = client
        self.now = now
    }

    /// Returns whether no device license is left in the queue.
    @discardableResult
    public func flushAndWait() async -> Bool {
        let ends = now() &+ deviceLicenseFlushMs
        // Set before the wait, so a send that already runs stops at its next request too.
        await client.limitSends(until: ends)
        var awaited: Set<Int> = []
        var sentAll = true
        // A send that starts while the flush runs is tracked work, so the next pass waits for it.
        while true {
            let pending = work.snapshot().filter { !awaited.contains($0.id) }
            for entry in pending {
                await entry.task.value
                awaited.insert(entry.id)
            }
            sentAll = await client.flush(within: max(ends &- now(), 0))
            let started = work.snapshot().contains { !awaited.contains($0.id) }
            if !started || now() >= ends { break }
        }
        await client.endLimit()
        return sentAll
    }
}
