// The shell every model SDK is built on. The download path needs the Hub, so
// what is pinned here is the behaviour an SDK used to hand-write and could get
// wrong: laziness, single-flight loading, progress, retry after failure, and
// offline availability.
import Testing
import DesertAnt

/// A model declaration that exists only here, pointing at a repo/revision no
/// test ever resolves - enough for the availability path, which is answered from
/// the filesystem alone.
private enum FakeModel: ModelDeclaration {
    static let id = "fake"
    static let product = "Fake"
    static let revision = "v0.0.1"
    static let sdkVersion = "0.0.1"
    static let summary = "A model that only exists in this test."
    static let files: [ModelPlatform: [String]] = Dictionary(
        uniqueKeysWithValues: ModelPlatform.allCases.map { ($0, ["fake.bin", "fake.json"]) })
    static func artifact(for platform: ModelPlatform) -> String { "fake.bin" }
}

private struct Runtime: Sendable, Hashable { let id: Int }

private struct LoadFailed: Error, Equatable {}

struct LoadedModelTests {
    @Test func constructionLoadsNothing() async throws {
        let builds = Counter()
        let model = LoadedModel<Runtime> {
            builds.increment()
            return Runtime(id: 1)
        }
        #expect(builds.value == 0, "construction must not build the runtime")
        _ = try await model.value()
        #expect(builds.value == 1)
    }

    @Test func theRuntimeIsBuiltOnceAndShared() async throws {
        let builds = Counter()
        let model = LoadedModel<Runtime> {
            builds.increment()
            return Runtime(id: builds.value)
        }
        // Concurrent first uses join one load rather than racing to build.
        let values = try await withThrowingTaskGroup(of: Runtime.self) { group in
            for _ in 0..<8 { group.addTask { try await model.value() } }
            var out: [Runtime] = []
            for try await value in group { out.append(value) }
            return out
        }
        #expect(builds.value == 1, "eight callers, one build")
        #expect(Set(values) == [Runtime(id: 1)])
        // A later call reuses it too.
        #expect(try await model.value() == Runtime(id: 1))
        #expect(builds.value == 1)
    }

    @Test func aFailedLoadIsNotCached() async throws {
        let attempts = Counter()
        let model = LoadedModel<Runtime> {
            attempts.increment()
            if attempts.value == 1 { throw LoadFailed() }
            return Runtime(id: attempts.value)
        }
        await #expect(throws: LoadFailed.self) { try await model.value() }
        // The failure must not be remembered: a retry gets a real value.
        #expect(try await model.value() == Runtime(id: 2))
        #expect(attempts.value == 2)
    }

    @Test func downloadReportsProgressAndEndsAtOne() async throws {
        let model = LoadedModel<Runtime> { Runtime(id: 1) }
        let fractions = Fractions()
        try await model.download { fractions.append($0) }
        #expect(fractions.values.last == 1)
        #expect(fractions.values == fractions.values.sorted(), "progress is monotonic")
        // Already loaded: a second download is a no-op that still reports done.
        try await model.download()
        #expect(model.isDownloaded(), "a supplied runtime needs no network")
    }

    @Test func availabilityIsAnsweredOfflineFromTheDirectory() async throws {
        // A directory with none of the model's files is not available, and asking
        // must not download anything.
        let model = LoadedModel(FakeModel.self, directory: "/desert-ant-tests/does-not-exist") { _ in
            Runtime(id: 1)
        }
        #expect(model.isDownloaded() == false)
    }
}

/// Minimal shared counters (the closures are `@Sendable`, so they cannot capture
/// a local `var`).
private final class Counter: @unchecked Sendable {
    private(set) var value = 0
    func increment() { value += 1 }
}

private final class Fractions: @unchecked Sendable {
    private(set) var values: [Double] = []
    func append(_ value: Double) { values.append(value) }
}
