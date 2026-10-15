import Testing

@testable import Who

/// How a recording is covered by the window the artifact traced.
struct PiecesTests {
    @Test func aRecordingInsideTheWindowIsOnePiece() {
        #expect(Pieces.cut(frames: 4000, window: 30000) == [Piece(first: 0, end: 4000)])
        #expect(Pieces.cut(frames: 30000, window: 30000) == [Piece(first: 0, end: 30000)])
    }

    @Test func aLongerRecordingIsCutEndToEnd() {
        let pieces = Pieces.cut(frames: 70000, window: 30000)
        #expect(pieces == [Piece(first: 0, end: 30000), Piece(first: 30000, end: 60000), Piece(first: 60000, end: 70000)])
        #expect(pieces.map(\.frames).reduce(0, +) == 70000)
    }

    @Test func aPiecePicksTheShortestWindowThatHoldsIt() {
        #expect(Pieces.window(for: 4000, among: [6000, 30000]) == 6000)
        #expect(Pieces.window(for: 6000, among: [6000, 30000]) == 6000)
        #expect(Pieces.window(for: 6001, among: [6000, 30000]) == 30000)
        #expect(Pieces.window(for: 90000, among: [6000, 30000]) == 30000)
    }
}
