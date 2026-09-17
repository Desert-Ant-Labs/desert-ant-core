import Foundation
import Testing
@testable import Inference

// The strategy, checked without hardware: which shape of parallelism a backend
// gets is the whole point, and it is decided by one bool.

private final class Session: InferenceSession, @unchecked Sendable {
    let runsConcurrently: Bool
    private let lock = NSLock()
    private var _seen: [Int] = []
    private var _peak = 0
    private var active = 0

    init(concurrent: Bool) { runsConcurrently = concurrent }

    var seen: [Int] { locked { _seen } }
    var peak: Int { locked { _peak } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    func run(inputs: [String: Tensor], outputs: [String], deviceId: String?) async throws -> [Tensor] {
        locked { active += 1; _peak = max(_peak, active) }
        try? await Task.sleep(nanoseconds: 1_000_000)
        locked { active -= 1 }
        return []
    }

    func note(_ item: Int) { locked { _seen.append(item) } }
}

private func drive(_ sessions: [Session], count: Int) async throws {
    try await ParallelRuns.run(count: count, sessions: sessions) { item, session in
        (session as! Session).note(item)
        _ = try await session.run(inputs: [:], outputs: [])
    }
}

@Test func aSessionThatOverlapsGetsSeveralInFlight() async throws {
    let session = Session(concurrent: true)
    try await drive([session], count: 16)
    #expect(session.seen.count == 16)
    #expect(session.peak > 1, "a concurrent session should be given more than one at a time")
    #expect(session.peak <= 4, "and no more than the depth")
}

@Test func aSessionThatLocksIsGivenOneAtATime() async throws {
    // LiteRT holds its session for the length of a run, so queueing behind it
    // buys nothing: the parallelism there is the pool, not the depth.
    let session = Session(concurrent: false)
    try await drive([session], count: 8)
    #expect(session.seen.count == 8)
    #expect(session.peak == 1)
}

@Test func aPoolSpreadsTheWorkEvenly() async throws {
    let pool = (0..<4).map { _ in Session(concurrent: false) }
    try await drive(pool, count: 16)
    #expect(pool.allSatisfy { $0.seen.count == 4 })
    #expect(pool.allSatisfy { $0.peak == 1 })
}

@Test func nothingToRunIsNotAnError() async throws {
    let session = Session(concurrent: true)
    try await drive([session], count: 0)
    try await ParallelRuns.run(count: 4, sessions: []) { _, _ in }
    #expect(session.seen.isEmpty)
}

@Test func aFailureStopsTheRunAndIsRethrown() async throws {
    struct Boom: Error {}
    let session = Session(concurrent: true)
    await #expect(throws: Boom.self) {
        try await ParallelRuns.run(count: 64, sessions: [session]) { item, _ in
            if item == 2 { throw Boom() }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
