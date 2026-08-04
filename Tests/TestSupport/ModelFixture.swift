// Shared test support for every model's suite: where model-backed tests run, and
// the one download they share.
//
// Both pieces used to be copied into each model's test target. Generic over
// `ModelDeclaration` instead, they work for any model in the catalog, so a new
// model's suite adds no fixture code.

import Foundation
import DesertAnt

#if !os(WASI)

/// The model for the tests that need one.
///
/// No model artifact is committed, so the suites use the same path users do: the
/// pinned revision is downloaded into the managed cache once, then reused offline
/// by every later run. The download is memoized per model for the lifetime of the
/// process, so parallel tests - and every model's suite - share one fetch.
public enum ModelFixture {
    /// The cached model directory for `model`, downloading it on the first call.
    public static func files<M: ModelDeclaration>(_ model: M.Type) async throws -> StoredModel {
        try await Downloads.shared.task(for: M.id) { try await M.resolve() }.value
    }

    /// Copy this platform's declared model files into `directory`, which is how a
    /// user pre-populates a location for a `<Model>(directory:)` initializer. Only
    /// the declared entries are copied, so the cache's `.dal-meta` bookkeeping is
    /// left behind.
    public static func populate<M: ModelDeclaration>(_ model: M.Type, into directory: URL) async throws {
        let files = try await files(model)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in M.files[.current] ?? [] {
            let name = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            try fm.copyItem(
                at: URL(fileURLWithPath: files.path(name)),
                to: directory.appendingPathComponent(name))
        }
    }
}

/// One download per model id. A `Task` cannot be a static stored property of a
/// generic type, so the memo lives in this lock-protected table keyed by the
/// catalog id instead.
private final class Downloads: @unchecked Sendable {
    static let shared = Downloads()

    private let lock = NSLock()
    private var tasks: [String: Task<StoredModel, Error>] = [:]

    func task(
        for id: String,
        _ resolve: @Sendable @escaping () async throws -> StoredModel
    ) -> Task<StoredModel, Error> {
        lock.withLock {
            if let existing = tasks[id] { return existing }
            let task = Task(operation: resolve)
            tasks[id] = task
            return task
        }
    }
}

#endif
