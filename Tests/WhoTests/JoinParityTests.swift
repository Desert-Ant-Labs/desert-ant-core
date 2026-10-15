import AudioIO
import Foundation
import Testing

@testable import Who

/// The join against the reference implementation on the same graphs: eleven minutes of real speech,
/// several pieces, so the voice graph, the pooling, the embedding and the clustering all run, and the
/// speakers it returns against the ones Python returned. The audio lives outside the repo:
///
///     WHO_MODEL_DIR=... WHO_FIXTURES_DIR=... swift test --filter WhoTests.JoinParityTests
@Suite(.serialized, .enabled(if: WhoFixtures.hasSchema2 && WhoFixtures.joinFixtures != nil,
                             "no join fixture: set WHO_MODEL_DIR and WHO_FIXTURES_DIR"))
struct JoinParityTests {
    struct Golden: Decodable {
        struct Lane: Decodable { let piece: Int; let query: Int; let solo_seconds: Double; let columns: Int; let speaker: Int }
        struct Segment: Decodable { let start: Double; let end: Double; let speaker: String }
        let excerpt: String
        let seconds: Double
        let pieces: Int
        let lanes: [Lane]
        let segments: [Segment]
    }

    @Test func joinsSeveralPiecesOfSpeechAsThePythonPipelineDoes() async throws {
        let directory = try #require(WhoFixtures.joinFixtures)
        let golden = try JSONDecoder().decode(Golden.self, from: try Data(contentsOf: URL(fileURLWithPath: directory + "/who_join_golden.json")))
        #expect(golden.pieces > 1 && golden.lanes.filter { $0.columns > 1 }.count > 1, "the golden must hold several pieces with voices")
        let who = try WhoFixtures.who()
        let result = try await who.diarize(path: directory + "/" + golden.excerpt)
        #expect(abs(result.duration - golden.seconds) < 0.01)

        let theirs = Set(golden.segments.map(\.speaker)).count
        #expect(result.speakerCount == theirs, "speakers: \(result.speakerCount) against python's \(theirs)")

        // The labels are arbitrary on both sides, so speakers are paired by best overlap, as the speech test does.
        let frames = Int(golden.seconds / SpeechParityTests.step)
        let want = SpeechParityTests.numbered(golden.segments.map { SpeechParityTests.Golden.Segment(start: $0.start, end: $0.end, speaker: $0.speaker) })
        let ours = SpeechParityTests.activity(result.turns.map { ($0.start, $0.end, $0.speaker) }, frames: frames)
        for ((i, j), agreement) in SpeechParityTests.bestPairing(ours, SpeechParityTests.activity(want, frames: frames)) {
            #expect(agreement > 0.9, "speaker \(i) against python speaker \(j): frames agree on \(agreement) of their union")
        }
    }
}
