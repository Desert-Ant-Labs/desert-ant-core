import Testing
import Transcript

struct ClipRanges {
    /// Two sentences spoken back to back, then a long pause, then a third.
    private let transcript = [
        Sentence(id: 0, text: "Zero.", start: 0, end: 1),
        Sentence(id: 1, text: "One.", start: 1, end: 2),
        Sentence(id: 2, text: "Two.", start: 30, end: 31),
    ]

    private func clip(_ ids: [Int]) -> Clip {
        Clip(id: 0, sentenceIDs: ids, text: "", score: 0, percentile: 0, estimatedDurationSec: 0)
    }

    @Test func contiguousSentencesMerge() {
        let ranges = clip([0, 1]).ranges(in: transcript, padding: 0)

        #expect(ranges.count == 1)
        #expect(ranges[0].start == 0)
        #expect(ranges[0].end == 2)
    }

    @Test func pausesAreCut() {
        let ranges = clip([1, 2]).ranges(in: transcript, padding: 0)

        #expect(ranges.count == 2)
        #expect(ranges[1].start == 30)
    }

    @Test func paddingStopsAtZero() {
        #expect(clip([0]).ranges(in: transcript, padding: 5).first?.start == 0)
    }

    @Test func overlappingPaddingMerges() {
        #expect(clip([0, 1]).ranges(in: transcript, padding: 2).count == 1)
    }

    @Test func noPaddingWithoutSilence() {
        // Sentence 0 ends exactly where 1 begins, so there is no silence to take.
        #expect(clip([1]).ranges(in: transcript, padding: 5)[0].start == 1)
    }

    @Test func paddingIsHalfTheSilence() {
        let close = [Sentence(id: 0, text: "A.", start: 0, end: 1),
                     Sentence(id: 1, text: "B.", start: 1.25, end: 2)]
        // A quarter-second gap gives an eighth of a second, not the full limit.
        #expect(clip([0]).ranges(in: close, padding: 5)[0].end == 1.125)
        // A long silence is capped rather than halved.
        #expect(clip([1]).ranges(in: transcript, padding: 0.15)[0].end == 2.15)
    }

    @Test func paddingAtTheEnd() {
        #expect(clip([2]).ranges(in: transcript, padding: 0.15)[0].end == 31.15)
    }

    @Test func unknownIdsAreSkipped() {
        // Selection addresses the array it was given; an id outside it means a
        // different transcript than the one selected from.
        #expect(clip([0, 99]).ranges(in: transcript, padding: 0).count == 1)
    }

    @Test func rangesAreOrdered() {
        #expect(clip([2, 0]).ranges(in: transcript, padding: 0).map(\.start) == [0, 30])
    }

    @Test func durationSumsSpans() {
        #expect(clip([0, 1]).duration(in: transcript, padding: 0) == 2)
        #expect(clip([1, 2]).duration(in: transcript, padding: 0) == 2)
    }
}
