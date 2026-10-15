// Turns on the recording's clock, labelled, and the vector arithmetic the join shares.

import Foundation

/// A stretch of one label's speech on the recording's clock: a query within a piece, a speaker across them.
struct LabelledTurn: Sendable, Equatable {
    let start: Double
    let end: Double
    let label: Int
}

enum Linker {
    /// A speaker's pieces that touch made one turn, so a turn cut at a piece's edge reads as one.
    static func joined(_ turns: [LabelledTurn]) -> [LabelledTurn] {
        var out: [LabelledTurn] = []
        for turn in turns.sorted(by: { ($0.label, $0.start) < ($1.label, $1.start) }) {
            if let last = out.last, last.label == turn.label, turn.start <= last.end + 1e-6 {
                out[out.count - 1] = LabelledTurn(start: last.start, end: max(last.end, turn.end), label: last.label)
            } else {
                out.append(turn)
            }
        }
        return out
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    static func unit(_ v: [Float]) -> [Float] {
        let norm = dot(v, v).squareRoot() + 1e-8
        return v.map { $0 / norm }
    }
}
