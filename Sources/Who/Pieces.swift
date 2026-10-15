// Covering a recording with the fixed-shape window the artifact traced.

/// One piece of a recording, in 10 ms frames; the end is exclusive.
struct Piece: Equatable {
    let first: Int
    let end: Int

    var frames: Int { end - first }
}

enum Pieces {
    /// The shortest traced window that holds `frames`, the longest if none does.
    static func window(for frames: Int, among windows: [Int]) -> Int {
        windows.first { $0 >= frames } ?? windows.last ?? frames
    }

    /// Pieces of `window` frames laid end to end, the last one short.
    static func cut(frames: Int, window: Int) -> [Piece] {
        guard frames > window else { return [Piece(first: 0, end: max(frames, 0))] }
        return stride(from: 0, to: frames, by: window).map { Piece(first: $0, end: min($0 + window, frames)) }
    }
}
