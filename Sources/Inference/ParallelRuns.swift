import Foundation

/// Run independent pieces of work across the inference backend, as widely as
/// that backend can take them.
///
/// Every model here has the same shape somewhere in it: a list of items that do
/// not depend on each other - windows of audio, chunks of a spectrogram, frames
/// of video - and a loop that hands them to a model one at a time. That loop
/// leaves the machine idle, but how much it leaves idle, and what to do about
/// it, depends on the runtime rather than the model:
///
/// - **Core ML** takes several requests in flight on one session and spreads
///   them itself, including across the two Neural Engines of an Ultra part.
///   Measured per call, Voz's encoder on an M3 Ultra: 34.8 ms one at a time,
///   16.8 ms with two in flight, 13.2 ms with four. On single-engine chips the
///   same depth is free rather than useful - an M5 goes 25.0 to 24.7 ms, an
///   iPhone 16 Pro 30.9 to 30.8 - because one window already fills the engine.
/// - **LiteRT** cannot: a session serializes its whole run under a mutex, so
///   concurrency there means several sessions, one request each. That is what
///   a caller's session pool is for, and why passing more than one session here
///   is how a LiteRT model uses more than one core.
///
/// So the caller says what its work is and hands over the sessions it has; this
/// decides how many to keep in flight. A pool of one on Core ML runs four deep;
/// a pool of four on LiteRT runs one deep in each.
public enum ParallelRuns {

    /// How many requests to keep in flight per session.
    ///
    /// Four rather than two because the second engine of an Ultra is not the
    /// only thing depth buys: a dispatch's fixed host cost is hidden by the
    /// next request being already queued, which is why the small models gain
    /// from it on every chip measured (Voz's mel, 0.31 ms to 0.13 on an M5).
    /// Above four nothing measured gains - an Ultra flattens at 13.2 ms - and
    /// each request in flight costs the caller a set of input buffers.
    ///
    /// One where a run holds a lock for its duration, since queueing behind it
    /// buys nothing and costs a task.
    public static func depth(perSession session: any InferenceSession) -> Int {
        if let pinned = ProcessInfo.processInfo.environment["DAL_RUN_DEPTH"],
           let value = Int(pinned), value > 0 { return value }
        return session.runsConcurrently ? 4 : 1
    }

    /// Run `count` items, `body` receiving the item index and the session to
    /// run it on. Rethrows the first failure and cancels the rest.
    ///
    /// Items may complete in any order. A caller that needs ordering should
    /// write into a preallocated slot per index, which is what every caller
    /// here does anyway.
    public static func run(
        count: Int,
        sessions: [any InferenceSession],
        body: @escaping @Sendable (Int, any InferenceSession) async throws -> Void
    ) async throws {
        guard count > 0, let first = sessions.first else { return }
        let inFlight = max(1, min(count, sessions.count * depth(perSession: first)))
        try await withThrowingTaskGroup(of: Void.self) { group in
            var issued = 0
            var running = 0
            while issued < count || running > 0 {
                while running < inFlight, issued < count {
                    let item = issued
                    // Items are spread over the pool rather than striped across
                    // it: with one session this is always that session, and
                    // with several it keeps each equally loaded however uneven
                    // the items turn out to be.
                    let session = sessions[item % sessions.count]
                    group.addTask { try await body(item, session) }
                    issued += 1
                    running += 1
                }
                try await group.next()
                running -= 1
            }
        }
    }
}
