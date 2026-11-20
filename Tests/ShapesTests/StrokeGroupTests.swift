import Testing
@testable import Shapes

/// Live snapping reads the strokes drawn with no long pause between them as one
/// drawing, so a plus drawn in two strokes snaps as a plus.
struct StrokeGroupTests {
    @Test func aStrokeSoonAfterTheLastJoinsIt() {
        var group = StrokeGroup(gap: 1)
        group.began(at: 0, count: 5)          // five strokes already on the canvas
        group.ended(at: 0.4)
        group.began(at: 0.9, count: 6)        // 0.5 s later
        #expect(group.earlier(count: 6) == 5..<6)
    }

    @Test func aLongPauseStartsANewDrawing() {
        var group = StrokeGroup(gap: 1)
        group.began(at: 0, count: 5)
        group.ended(at: 0.4)
        group.began(at: 2, count: 6)          // 1.6 s later
        #expect(group.earlier(count: 6).isEmpty)
    }

    @Test func aDrawingKeepsAtMostItsLimit() {
        var group = StrokeGroup(gap: 1, limit: 3)
        var time = 0.0
        for count in 0..<6 {
            group.began(at: time, count: count)
            group.ended(at: time + 0.2)
            time += 0.5
        }
        group.began(at: time, count: 6)
        #expect(group.earlier(count: 6) == 4..<6)   // two earlier strokes and this one
    }

    @Test func aZeroGapReadsEveryStrokeAlone() {
        var group = StrokeGroup(gap: 0)
        group.began(at: 0, count: 0)
        group.ended(at: 0.1)
        group.began(at: 0.2, count: 1)
        #expect(group.earlier(count: 1).isEmpty)
    }

    @Test func aResetBreaksTheDrawing() {
        var group = StrokeGroup(gap: 1)
        group.began(at: 0, count: 2)
        group.ended(at: 0.3)
        group.reset(count: 2)                 // a snap, an undo or the eraser
        group.began(at: 0.5, count: 2)
        #expect(group.earlier(count: 2).isEmpty)
    }

    @Test func strokesTakenAwayNeverLeaveARangePastTheCanvas() {
        var group = StrokeGroup(gap: 1)
        group.began(at: 0, count: 4)
        group.ended(at: 0.2)
        group.began(at: 0.5, count: 3)        // a stroke was undone meanwhile
        #expect(group.earlier(count: 3).upperBound == 3)
        #expect(group.earlier(count: 3).isEmpty)
    }
}
