import Testing

@testable import Who

/// The voice path's arithmetic: the windows the voice graph reads, a lane's column mask, the clustering,
/// and the stitching of a speaker's touching turns.
struct VoicesTests {
    @Test func aShortRecordingIsOnePaddedWindow() {
        let windows = Voices.windows(melFrames: 800, width: 3256, margin: 128, perColumn: 8)
        #expect(windows == [VoiceWindow(start: 0, keepLow: 0, keepHigh: 100, placeLow: 0)])
    }

    @Test func windowsOverlapByTheMarginAndCoverTheRecordingOnce() {
        let windows = Voices.windows(melFrames: 9000, width: 3256, margin: 128, perColumn: 8)
        #expect(windows.first?.start == 0 && windows.first?.keepLow == 0)
        #expect(windows.last!.start + 3256 == 9000, "the last window ends at the recording's end")
        var placed = 0
        for window in windows {
            #expect(window.placeLow == placed, "kept columns land where the previous window stopped")
            placed += window.keepHigh - window.keepLow
        }
        #expect(placed == 9000 / 8)
        for (a, b) in zip(windows, windows.dropFirst()) { #expect(b.start == a.start + 3256 - 256 || b.start == 9000 - 3256) }
    }

    @Test func aLaneWithoutAVoiceFoldsIntoTheVoicedLaneNearestItInTime() {
        func turns(_ spans: [(Double, Double)]) -> [LabelledTurn] { spans.map { LabelledTurn(start: $0.0, end: $0.1, label: 0) } }
        let voiced = [turns([(0, 10), (20, 30)]), turns([(12, 18)])]
        let lanes = [0, 1]
        #expect(Voices.nearest(to: turns([(10.5, 11)]), among: voiced, lanes: lanes) == 0)          // 0.5 s from lane 0, 1 s from lane 1
        #expect(Voices.nearest(to: turns([(16, 21)]), among: voiced, lanes: lanes) == 1)            // 2 s inside lane 1 against 1 s inside lane 0
        #expect(Voices.nearest(to: turns([(17, 21)]), among: voiced, lanes: lanes) == 0)            // 1 s with each: the first wins the tie
        #expect(Voices.nearest(to: turns([(17.5, 21)]), among: voiced, lanes: lanes) == 0)          // 0.5 s with lane 1, 1 s with lane 0
        #expect(Voices.nearest(to: turns([(14, 20.5)]), among: voiced, lanes: lanes) == 1)          // 4 s with lane 1, 0.5 s with lane 0
        #expect(Voices.nearest(to: turns([(40, 41)]), among: voiced, lanes: lanes) == 0)            // 10 s from lane 0, 22 from lane 1
        #expect(Voices.firstAppearance([3, 3, 0, 5, 0]) == [0, 0, 1, 2, 1])
    }

    @Test func aColumnIsTheLanesWhenHalfItsFramesAre() {
        var solo = [Float](repeating: 0, count: 24)
        for f in 0..<4 { solo[f] = 1 }                                                      // half of column 0
        for f in 8..<11 { solo[f] = 1 }                                                     // under half of column 1
        for f in 16..<24 { solo[f] = 1 }                                                    // all of column 2
        #expect(Voices.columnMask(solo: solo, offset: 0, columns: 4, perColumn: 8) == [true, false, true, false])
        #expect(Voices.columnMask(solo: solo, offset: 8, columns: 4, perColumn: 8) == [false, true, false, true])
    }

    @Test func averageLinkageJoinsTheNearAndKeepsTheFarApart() {
        let a: [Float] = [1, 0, 0], b: [Float] = [0, 1, 0], nearA: [Float] = [0.96, 0.28, 0]
        #expect(AverageLinkage.cluster([a, b, Linker.unit(nearA), b], cosine: 0.55) == [0, 1, 0, 1])
        #expect(AverageLinkage.cluster([a], cosine: 0.55) == [0])
        #expect(AverageLinkage.cluster([], cosine: 0.55) == [])
    }

    @Test func touchingTurnsOfOneSpeakerBecomeOne() {
        let turns = [LabelledTurn(start: 0, end: 1, label: 3), LabelledTurn(start: 1, end: 2.5, label: 3),
                     LabelledTurn(start: 4, end: 5, label: 3), LabelledTurn(start: 1, end: 2, label: 1)]
        #expect(Linker.joined(turns) == [LabelledTurn(start: 1, end: 2, label: 1), LabelledTurn(start: 0, end: 2.5, label: 3),
                                         LabelledTurn(start: 4, end: 5, label: 3)])
    }
}

/// The kept-distance clustering against the definition, pair by pair, on random vectors.
struct AverageLinkageTests {
    /// Average linkage from the definition: recompute every pair's mean distance at every merge.
    static func reference(_ unit: [[Float]], cosine: Float) -> [Int] {
        let n = unit.count
        var members: [[Int]] = (0..<n).map { [$0] }
        while members.count > 1 {
            var best: Float = .infinity, pair = (0, 0)
            for a in 0..<members.count {
                for b in (a + 1)..<members.count {
                    var sum: Float = 0
                    for i in members[a] { for j in members[b] { sum += 1 - Linker.dot(unit[i], unit[j]) } }
                    let mean = sum / Float(members[a].count * members[b].count)
                    if mean < best { best = mean; pair = (a, b) }
                }
            }
            guard best < 1 - cosine else { break }
            members[pair.0] += members[pair.1]
            members.remove(at: pair.1)
        }
        var labels = [Int](repeating: 0, count: n)
        for (k, group) in members.sorted(by: { $0.min()! < $1.min()! }).enumerated() { for i in group { labels[i] = k } }
        return labels
    }

    @Test func matchesTheDefinitionOnRandomVectors() {
        var generator = SeededGenerator(seed: 7)
        let centres: [[Float]] = (0..<6).map { _ in Linker.unit((0..<16).map { _ in Float.random(in: -1...1, using: &generator) }) }
        let vectors: [[Float]] = (0..<60).map { i in
            Linker.unit(zip(centres[i % 6], (0..<16).map { _ in Float.random(in: -0.25...0.25, using: &generator) }).map { $0 + $1 })
        }
        for cosine: Float in [0.4, 0.55, 0.7, 0.9] {
            #expect(AverageLinkage.cluster(vectors, cosine: cosine) == Self.reference(vectors, cosine: cosine), "at cosine \(cosine)")
        }
    }
}

/// A seeded generator, so the random test is the same test every run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
