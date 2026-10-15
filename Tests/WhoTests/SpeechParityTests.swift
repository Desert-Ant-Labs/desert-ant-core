import Foundation
import Testing

@testable import Who

/// The pipeline on two minutes of real speech, against the reference implementation's turns. The audio
/// lives outside the repo:
///
///     WHO_MODEL_DIR=... WHO_FIXTURES_DIR=... swift test --filter WhoTests.SpeechParityTests
@Suite(.serialized, .enabled(if: WhoFixtures.hasSchema2 && WhoFixtures.speechFixtures != nil,
                             "no speech fixture: set WHO_MODEL_DIR and WHO_FIXTURES_DIR"))
struct SpeechParityTests {
    struct Golden: Decodable {
        struct Piece: Decodable { let frames: Int; let queries: Int; let presence_logits: [Float] }
        struct Segment: Decodable { let start: Double; let end: Double; let speaker: String }
        let excerpt: String
        let seconds: Double
        let pieces: [Piece]
        let segments: [Segment]
    }

    static let step = 0.01

    /// The one-to-one pairing of speakers maximising the summed frame agreement, by enumeration; each pair with its agreement.
    static func bestPairing(_ a: [[Bool]], _ b: [[Bool]]) -> [((Int, Int), Double)] {
        func agreement(_ x: [Bool], _ y: [Bool]) -> Double {
            let both = zip(x, y).filter { $0 && $1 }.count, either = zip(x, y).filter { $0 || $1 }.count
            return either == 0 ? 1.0 : Double(both) / Double(either)
        }
        func permutations(_ items: [Int]) -> [[Int]] {
            items.count <= 1 ? [items] : items.flatMap { head in permutations(items.filter { $0 != head }).map { [head] + $0 } }
        }
        let n = min(a.count, b.count)
        var best: [((Int, Int), Double)] = []
        var bestTotal = -1.0
        for order in permutations(Array(0..<b.count)) {
            let scored = (0..<n).map { ((($0, order[$0])), agreement(a[$0], b[order[$0]])) }
            let total = scored.map(\.1).reduce(0, +)
            if total > bestTotal { bestTotal = total; best = scored }
        }
        return best
    }

    /// Each speaker's activity per frame, speakers in order of first appearance; a frame covers `[f, f + 1)` steps.
    static func activity(_ turns: [(start: Double, end: Double, speaker: Int)], frames: Int) -> [[Bool]] {
        let order = turns.sorted { $0.start < $1.start }.map(\.speaker).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        var rows = [[Bool]](repeating: [Bool](repeating: false, count: frames), count: order.count)
        for turn in turns {
            let row = order.firstIndex(of: turn.speaker)!
            let first = max(Int((turn.start / step).rounded()), 0), last = min(Int((turn.end / step).rounded()) - 1, frames - 1)
            if first <= last { for f in first...last { rows[row][f] = true } }
        }
        return rows
    }

    /// The golden's string labels as indices, in order of first appearance.
    static func numbered(_ segments: [Golden.Segment]) -> [(start: Double, end: Double, speaker: Int)] {
        var labels: [String: Int] = [:]
        for segment in segments.sorted(by: { $0.start < $1.start }) where labels[segment.speaker] == nil {
            labels[segment.speaker] = labels.count
        }
        return segments.map { ($0.start, $0.end, labels[$0.speaker]!) }
    }

    static func golden() throws -> Golden {
        let directory = try #require(WhoFixtures.speechFixtures)
        return try JSONDecoder().decode(Golden.self, from: try Data(contentsOf: URL(fileURLWithPath: directory + "/who_speech_golden.json")))
    }

    @Test func findsTheSpeakersThePythonPipelineFound() async throws {
        let directory = try #require(WhoFixtures.speechFixtures)
        let golden = try Self.golden()
        let frames = try #require(golden.pieces.first).frames
        let who = try WhoFixtures.who()
        let result = try await who.diarize(path: directory + "/" + golden.excerpt)
        #expect(abs(result.duration - golden.seconds) < 0.01)

        let want = Self.numbered(golden.segments)
        #expect(result.speakerCount == Set(want.map(\.speaker)).count, "speakers: \(result.speakerCount) against \(Set(want.map(\.speaker)).count)")
        #expect(!result.turns.isEmpty)

        // The labels are arbitrary on both sides, so speakers are paired by best overlap.
        let ours = Self.activity(result.turns.map { ($0.start, $0.end, $0.speaker) }, frames: frames)
        for ((i, j), agreement) in Self.bestPairing(ours, Self.activity(want, frames: frames)) {
            #expect(agreement > 0.95, "speaker \(i) against python speaker \(j): frames agree on \(agreement) of their union")
        }
    }
}
