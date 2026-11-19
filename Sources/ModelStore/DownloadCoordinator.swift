// Runs the downloads (and manifest records) at one cache location one at a time.
//
// `ModelStore` is a value type, recreated per call, so it cannot itself hold
// "a download is already running for this location". Two callers racing the
// same model (two test suites in one process, or a server handling two requests
// that both need a model not yet cached) would each run the full download,
// writing the same `<location>/.dal-meta/<file>.part` temp and moving it into
// the same destination. Their writes interleave and the model lands corrupt
// (Core ML then fails to open a half-written `weights/weight.bin`).
//
// This process-global actor keys an in-flight `Task` by cache location. The
// first caller starts the download; everyone else on the same location waits
// for it, then runs their own, which finds the files already there. Waiting
// rather than sharing the result matters because specs that share a location
// can ask for different files (Face's detector alone, or the detector and the
// embedder). Different locations still run in parallel. It does not guard
// against a *second process* racing the same cache dir; that needs a file lock,
// and no pipeline here runs two processes against one cache.

actor DownloadCoordinator {
    static let shared = DownloadCoordinator()

    /// What runs at each location, settled once it ends, whichever way.
    private var inFlight: [String: (id: Int, done: Task<Void, Never>)] = [:]
    private var nextID = 0

    /// Runs `body` alone at `location`: after whatever runs there now, before whatever asks next. Downloads and
    /// manifest records both go through here, since both rewrite the location's manifest.
    func run<T: Sendable>(location: String, _ body: @Sendable @escaping () async throws -> T) async throws -> T {
        // Wait out the work in flight here. Its failure is its caller's;
        // this caller then runs its own. A finished task's entry is dropped by
        // whoever sees it first: awaiting a finished task need not suspend, so
        // its own caller may not get back onto the actor before this loop runs again.
        while let (id, done) = inFlight[location] {
            await done.value
            if inFlight[location]?.id == id { inFlight[location] = nil }
        }
        nextID += 1
        let id = nextID
        let task = Task { try await body() }
        inFlight[location] = (id, Task { _ = try? await task.value })
        defer { if inFlight[location]?.id == id { inFlight[location] = nil } }
        return try await task.value
    }
}
