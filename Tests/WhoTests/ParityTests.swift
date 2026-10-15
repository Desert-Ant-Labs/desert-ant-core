import Foundation
import Testing

@testable import Who

/// The pipeline against the reference implementation on the same graphs: the queries and the decided
/// speakers on a formula signal.
@Suite(.serialized, .enabled(if: WhoFixtures.hasModel, "no model: set WHO_MODEL_DIR"))
struct ParityTests {
    struct Golden: Decodable {
        struct Piece: Decodable {
            let start_s: Double
            let frames: Int
            let queries: Int
            let presence_logits: [Float]
            let query_row_means: [Float]
        }
        struct Segment: Decodable { let start: Double; let end: Double; let speaker: String }
        let pieces: [Piece]
        let segments: [Segment]
    }

    static func golden() throws -> Golden {
        let url = try #require(Bundle.module.url(forResource: "who_parity_golden", withExtension: "json"))
        return try JSONDecoder().decode(Golden.self, from: try Data(contentsOf: url))
    }

    @Test func matchesThePythonPipelineOnTheFormulaSignal() async throws {
        let golden = try Self.golden()
        let piece = try #require(golden.pieces.first)
        #expect(golden.pieces.count == 1, "the formula signal fits one piece")
        let who = try WhoFixtures.who()
        try await who.download()
        let model = try await who.loadedModel()
        let (presence, _, queries, frames) = try await model.logits(Signals.turns())
        #expect(frames == piece.frames && presence.count == piece.queries)

        let dim = queries.count / piece.queries
        var worstQuery: Float = 0
        for m in 0..<piece.queries {
            var sum: Float = 0
            for d in 0..<dim { sum += queries[m * dim + d] }
            worstQuery = max(worstQuery, abs(sum / Float(dim) - piece.query_row_means[m]))
        }
        #expect(worstQuery < 0.01, "query row means differ by up to \(worstQuery)")

        let ours = Set(presence.indices.filter { presence[$0] > 0 })
        let theirs = Set(piece.presence_logits.indices.filter { piece.presence_logits[$0] > 0 })
        #expect(ours == theirs, "speakers decided differ: \(ours) against \(theirs)")
        #expect(Set(golden.segments.map(\.speaker)).count <= ours.count)
    }
}
