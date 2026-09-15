#if canImport(CoreML)
import Dispatch
import Foundation

/// Counters for the only thing that costs anything: Core ML dispatches.
///
/// A pass over ten minutes of speech spends 96% of its time inside three
/// `predict` calls and 4% in every line of Swift around them, so the useful
/// question about a change is never how fast the host code is. It is how many
/// times the encoder and the decode step were asked to run. Off unless
/// `VOZ_PROF` is set, and three integer increments when it is.
enum Diagnostics {
    nonisolated(unsafe) static let enabled =
        ProcessInfo.processInfo.environment["VOZ_PROF"] != nil
    nonisolated(unsafe) static var encoderCalls = 0
    nonisolated(unsafe) static var decodeCalls = 0
    nonisolated(unsafe) static var retries = 0
    /// Live lanes per decode dispatch, summed. A dispatch costs by its lane
    /// count whether or not those lanes carry a window, so the useful number is
    /// not how many dispatches ran but how full they were: lane_occupancy is
    /// the mean, and a low one means the model is being paid for work it is not
    /// doing.
    /// Nanoseconds inside each of the three `predict` calls. The phase split is
    /// not the same on every chip - an M3 Ultra puts the decode step on the CPU
    /// where an M1 keeps it on the Neural Engine - so it has to be measured on
    /// the host being optimized rather than carried over.
    nonisolated(unsafe) static var melNanos: UInt64 = 0
    nonisolated(unsafe) static var encoderNanos: UInt64 = 0
    nonisolated(unsafe) static var decodeNanos: UInt64 = 0
    /// Decode time that outlived the encoder pass. The overlap only pays for
    /// the decode it hides; this is the part it does not.
    nonisolated(unsafe) static var tailNanos: UInt64 = 0
    nonisolated(unsafe) static var liveLanes = 0
    nonisolated(unsafe) static var laneHistogram = [Int](repeating: 0, count: 65)

    /// Times `body` into `counter` when profiling, and gets out of the way when
    /// not: one branch, and the clock is only read on the enabled path.
    @inline(__always) static func time<T>(_ counter: inout UInt64,
                                          _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let started = DispatchTime.now().uptimeNanoseconds
        defer { counter += DispatchTime.now().uptimeNanoseconds - started }
        return try body()
    }

    @inline(__always) static func lanes(_ live: Int) {
        if enabled {
            liveLanes += live
            if live < laneHistogram.count { laneHistogram[live] += 1 }
        }
    }

    @inline(__always) static func count(_ counter: inout Int) {
        if enabled { counter += 1 }
    }

    /// Report and reset, so a process that transcribes repeatedly reports per
    /// transcription rather than cumulatively.
    static func report() {
        guard enabled else { return }
        let occupancy = decodeCalls > 0 ? Double(liveLanes) / Double(decodeCalls) : 0
        let line = "PROF encoder_calls=\(encoderCalls) decode_calls=\(decodeCalls)"
            + " retried_windows=\(retries)"
            + String(format: " lane_occupancy=%.2f", occupancy)
            + String(format: " mel_ms=%.1f", Double(melNanos) / 1e6)
            + String(format: " encoder_ms=%.1f", Double(encoderNanos) / 1e6)
            + String(format: " decode_ms=%.1f", Double(decodeNanos) / 1e6)
            + String(format: " decode_tail_ms=%.1f", Double(tailNanos) / 1e6) + "\n"
        FileHandle.standardError.write(Data(line.utf8))
        let counts = laneHistogram.enumerated().filter { $0.element > 0 }
            .map { "\($0.offset):\($0.element)" }.joined(separator: " ")
        FileHandle.standardError.write(Data("PROFLANES \(counts)\n".utf8))
        encoderCalls = 0
        decodeCalls = 0
        retries = 0
        liveLanes = 0
        melNanos = 0; encoderNanos = 0; decodeNanos = 0; tailNanos = 0
        laneHistogram = [Int](repeating: 0, count: 65)
    }
}
#endif
