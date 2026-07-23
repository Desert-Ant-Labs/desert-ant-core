import Testing
import Foundation
@testable import PlatformSupport

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}

struct LazyLoaderTests {
    @Test func constructionDoesNotLoad() async throws {
        let runs = Counter()
        _ = LazyLoader<Int> { _ in runs.bump(); return 1 }
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(runs.count == 0)  // never started
    }

    @Test func singleFlightForConcurrentCallers() async throws {
        let runs = Counter()
        let loader = LazyLoader<Int> { _ in
            runs.bump()
            try await Task.sleep(nanoseconds: 20_000_000)
            return 42
        }
        async let a = loader.value()
        async let b = loader.value()
        async let c = loader.value()
        let values = try await [a, b, c]
        #expect(values == [42, 42, 42])
        #expect(runs.count == 1)  // loaded once, shared

        _ = try await loader.value()   // cached
        #expect(runs.count == 1)
    }

    @Test func progressReachesOneAndIsMonotonic() async throws {
        let loader = LazyLoader<Int> { progress in
            progress(0.5)
            progress(0.25)  // out of order: must be ignored (monotonic)
            progress(0.75)
            return 7
        }
        let seen = Values()
        try await loader.run { seen.append($0) }
        #expect(seen.values.last == 1.0)
        #expect(seen.values == seen.values.sorted())  // non-decreasing
    }

    @Test func failureResetsSoRetryWorks() async throws {
        let runs = Counter()
        final class Flag: @unchecked Sendable { var fail = true }
        let flag = Flag()
        let loader = LazyLoader<Int> { _ in
            runs.bump()
            if flag.fail { throw CancellationError() }
            return 5
        }
        do { _ = try await loader.value(); Issue.record("expected failure") } catch {}
        flag.fail = false
        let value = try await loader.value()  // retried
        #expect(value == 5)
        #expect(runs.count == 2)
    }
}

final class Values: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func append(_ v: Double) { lock.withLock { storage.append(v) } }
    var values: [Double] { lock.withLock { storage } }
}
