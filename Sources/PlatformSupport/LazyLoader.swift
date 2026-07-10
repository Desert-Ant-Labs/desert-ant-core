/// Loads a value exactly once, on demand, and shares that single load with every
/// caller. Construction never triggers it; the first ``value()`` or
/// ``run(progress:)`` does. Concurrent callers join the same in-flight load and
/// all receive its progress (monotonic, `0...1`). A failed load is reset so a
/// later call retries.
///
/// Model SDKs use this to load (and download) a model lazily and single-flight,
/// without reimplementing the concurrency each time:
///
/// ```swift
/// let loader = LazyLoader { progress in try await downloadAndBuildModel(progress) }
/// let model = try await loader.value()          // loads on first use
/// try await loader.run { fraction in … }        // or prefetch with progress
/// ```
public actor LazyLoader<Value: Sendable> {
    public typealias Progress = @Sendable (Double) -> Void
    /// Produce the value, reporting progress `0...1` as it goes.
    public typealias Work = @Sendable (@escaping Progress) async throws -> Value

    private let work: Work
    private var task: Task<Value, Error>?
    private var observers: [Int: Progress] = [:]
    private var nextObserver = 0
    private var fraction = 0.0

    public init(_ work: @escaping Work) {
        self.work = work
    }

    /// The loaded value, starting the single shared load if it has not begun.
    public func value() async throws -> Value {
        let task = startIfNeeded()
        do {
            return try await task.value
        } catch {
            self.task = nil  // failed load: allow a later retry
            throw error
        }
    }

    /// Drive the shared load to completion while receiving its progress. Joining
    /// an in-flight load reports the progress already made, then the rest.
    public func run(progress: @escaping Progress) async throws {
        let id = addObserver(progress)
        defer { removeObserver(id) }
        progress(fraction)
        _ = try await value()
        progress(1)
    }

    private func startIfNeeded() -> Task<Value, Error> {
        if let task { return task }
        fraction = 0
        let task = Task { [work] in
            try await work { value in Task { await self.report(value) } }
        }
        self.task = task
        return task
    }

    private func report(_ value: Double) {
        guard value > fraction else { return }  // monotonic
        fraction = value
        for observer in observers.values { observer(value) }
    }

    private func addObserver(_ observer: @escaping Progress) -> Int {
        nextObserver += 1
        observers[nextObserver] = observer
        return nextObserver
    }

    private func removeObserver(_ id: Int) { observers[id] = nil }
}
