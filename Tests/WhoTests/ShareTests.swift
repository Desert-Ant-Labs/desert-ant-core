import Testing
@testable import Who

@Suite struct ShareTests {
    let result = Diarization(turns: [
        Turn(start: 0, end: 60, speaker: 0), Turn(start: 60, end: 61, speaker: 1), Turn(start: 61, end: 100, speaker: 2), Turn(start: 100, end: 103, speaker: 1),
    ], duration: 100)

    @Test func keepsEveryoneAtZero() {
        #expect(result.speakers(withMinimumShare: 0) == [0, 1, 2])
        #expect(result.keepingSpeakers(minimumShare: 0) == result)
    }

    @Test func dropsTheSpeakerUnderTheShare() {
        #expect(result.speakers(withMinimumShare: 0.05) == [0, 2])
        let kept = result.keepingSpeakers(minimumShare: 0.05)
        #expect(kept.speakerCount == 2)
        #expect(kept.turns == [Turn(start: 0, end: 60, speaker: 0), Turn(start: 61, end: 100, speaker: 1)])
    }

    @Test func aSpeakerOnTheLineStays() {
        #expect(result.speakers(withMinimumShare: 0.04) == [0, 1, 2])
    }
}
