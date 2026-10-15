// A voice per lane: the released trunk's columns over the recording in windows, pooled over the
// columns where that lane speaks alone, through the embedding sidecar; then the lanes clustered.

import Foundation

/// One window of the voice graph: where it reads from the recording, and which of its columns are kept.
struct VoiceWindow: Equatable {
    /// The window's first voice-filterbank frame.
    let start: Int
    /// The columns of the window's output that are kept, in window coordinates.
    let keepLow: Int
    let keepHigh: Int
    /// Where the kept columns land in the recording.
    let placeLow: Int
}

enum Voices {
    /// Windows over `melFrames` voice-filterbank frames: `width` each, overlapping by `margin` a side,
    /// the first at the recording's start and the last ending at its end; a recording shorter than one
    /// window is one padded window. Output coordinates are columns, one per `perColumn` frames.
    static func windows(melFrames: Int, width: Int, margin: Int, perColumn: Int) -> [VoiceWindow] {
        let columns = melFrames / perColumn
        if melFrames <= width {
            return [VoiceWindow(start: 0, keepLow: 0, keepHigh: columns, placeLow: 0)]
        }
        var out: [VoiceWindow] = []
        var kept = 0, start = 0
        while kept < columns {
            let last = start + width >= melFrames
            if last { start = melFrames - width }
            let end = last ? columns : (start + width - margin) / perColumn
            out.append(VoiceWindow(start: start, keepLow: kept - start / perColumn, keepHigh: end - start / perColumn, placeLow: kept))
            kept = end
            start += width - 2 * margin
        }
        return out
    }

    /// A lane's solo frames at 10 ms, placed at its piece's offset, as a mask over the recording's columns:
    /// a column is the lane's when at least half its frames are. Only the columns the piece covers are
    /// visited; the rest are false.
    static func columnMask(solo: [Float], offset: Int, columns: Int, perColumn: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: columns)
        let first = max(offset / perColumn, 0), last = min((offset + solo.count + perColumn - 1) / perColumn, columns)
        guard first < last else { return out }
        for c in first..<last {
            var on = 0
            for f in 0..<perColumn {
                let t = c * perColumn + f - offset
                if t >= 0, t < solo.count, solo[t] > 0 { on += 1 }
            }
            out[c] = 2 * on >= perColumn
        }
        return out
    }
}

extension Voices {
    /// Of the voiced lanes, the one nearest `turns` in time: the smallest gap between a turn of each, an
    /// overlap counting as no gap, and the most overlap deciding among those; the first wins a tie.
    /// Returns its index in `lanes`.
    static func nearest(to turns: [LabelledTurn], among candidates: [[LabelledTurn]], lanes: [Int]) -> Int {
        var best = lanes[0]
        var bestGap = Double.infinity, bestOverlap = -Double.infinity
        for (candidate, lane) in zip(candidates, lanes) {
            var gap = Double.infinity, overlap = 0.0
            for a in turns {
                for b in candidate {
                    let shared = min(a.end, b.end) - max(a.start, b.start)
                    gap = min(gap, max(0, -shared))
                    overlap += max(0, shared)
                }
            }
            if gap < bestGap || (gap == bestGap && overlap > bestOverlap) {
                best = lane
                bestGap = gap
                bestOverlap = overlap
            }
        }
        return best
    }

    /// The same partition numbered in order of first appearance.
    static func firstAppearance(_ labels: [Int]) -> [Int] {
        var numbered: [Int: Int] = [:]
        return labels.map { label in
            if let n = numbered[label] { return n }
            numbered[label] = numbered.count
            return numbered.count - 1
        }
    }
}

enum AverageLinkage {
    /// Average-linkage clustering on cosine distance: the closest two clusters merge while their mean
    /// pairwise distance is under `1 - cosine`. The distances between clusters are kept and updated on each
    /// merge (Lance-Williams), so a few hundred lanes cost milliseconds. Labels are numbered in order of
    /// first appearance.
    static func cluster(_ unit: [[Float]], cosine: Float) -> [Int] {
        let n = unit.count
        guard n > 1 else { return [Int](repeating: 0, count: n) }
        let threshold = 1 - cosine
        var distance = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let d = 1 - Linker.dot(unit[i], unit[j])
                distance[i * n + j] = d
                distance[j * n + i] = d
            }
        }
        var size = [Int](repeating: 1, count: n)
        var alive = [Bool](repeating: true, count: n)
        var member = Array(0..<n)                                                            // each lane's current cluster
        while true {
            var best: Float = .infinity
            var pair = (-1, -1)
            for a in 0..<n where alive[a] {
                for b in (a + 1)..<n where alive[b] && distance[a * n + b] < best {
                    best = distance[a * n + b]
                    pair = (a, b)
                }
            }
            guard pair.0 >= 0, best < threshold else { break }
            let (a, b) = pair
            for c in 0..<n where alive[c] && c != a && c != b {
                let merged = (Float(size[a]) * distance[a * n + c] + Float(size[b]) * distance[b * n + c]) / Float(size[a] + size[b])
                distance[a * n + c] = merged
                distance[c * n + a] = merged
            }
            size[a] += size[b]
            alive[b] = false
            for i in 0..<n where member[i] == b { member[i] = a }
        }
        var labels = [Int](repeating: -1, count: n)
        var next = 0
        var numbered: [Int: Int] = [:]
        for i in 0..<n {
            if numbered[member[i]] == nil { numbered[member[i]] = next; next += 1 }
            labels[i] = numbered[member[i]]!
        }
        return labels
    }
}
