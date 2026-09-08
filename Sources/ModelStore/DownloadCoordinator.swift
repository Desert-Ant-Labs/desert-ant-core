// Coalesces concurrent downloads of the same model into one.
//
// `ModelStore` is a value type, recreated per call, so it cannot itself hold
// "a download is already running for this location". Two callers racing the
// same model (two test suites in one process, or a server handling two requests
// that both need a model not yet cached) would each run the full download,
// writing the same `<location>/.dal-meta/<file>.part` temp and moving it into
// the same destination. Their writes interleave and the model lands corrupt:
// the symptom was Core ML failing to open a half-written `weights/weight.bin`.
//
// This process-global actor keys an in-flight `Task` by cache location. The
// first caller starts the download; everyone else on the same location awaits
// the same task. Different locations still run in parallel, and once a download
// finishes its entry is dropped so the next miss re-runs. It does not guard
// against a *second process* racing the same cache dir; that needs a file lock,
// and no pipeline here runs two processes against one cache.

actor DownloadCoordinator {
    static let shared = DownloadCoordinator()

    private var inFlight: [String: Task<StoredModel, Error>] = [:]

    func run(location: String, _ body: @Sendable @escaping () async throws -> StoredModel)
        async throws -> StoredModel
    {
        // Join an existing download for this location rather than starting a
        // second one. A failed task is not cached (the entry is cleared in the
        // `defer` below), so a later caller retries cleanly.
        if let existing = inFlight[location] {
            return try await existing.value
        }
        let task = Task { try await body() }
        inFlight[location] = task
        defer { inFlight[location] = nil }
        return try await task.value
    }
}
