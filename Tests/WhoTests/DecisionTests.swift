import Testing

@testable import Who

struct DecisionTests {
    static let trained = Decision(presenceThreshold: 0.5, maskThreshold: 0.5, rule: .product, pool: 1)

    @Test func aQueryBelowThePresenceThresholdNeverSpeaks() {
        let stretches = Self.trained.stretches(presence: [0.4, 0.9], masks: [0.9, 0.9, 0.9, 0.1, 0.9, 0.9], frames: 3)
        #expect(stretches == [Decision.Stretch(query: 1, first: 1, end: 3)])
    }

    @Test func theProductRuleNeedsTheMaskToClearTheThresholdScaledByPresence() {
        // Presence 0.6: the product passes 0.5 only where the mask is above 0.8333.
        let stretches = Self.trained.stretches(presence: [0.6], masks: [0.9, 0.8, 0.85, 0.2], frames: 4)
        #expect(stretches == [Decision.Stretch(query: 0, first: 0, end: 1), Decision.Stretch(query: 0, first: 2, end: 3)])
        let maskAlone = Decision(presenceThreshold: 0.5, maskThreshold: 0.5, rule: .mask, pool: 1)
        #expect(maskAlone.stretches(presence: [0.6], masks: [0.9, 0.8, 0.85, 0.2], frames: 4) == [Decision.Stretch(query: 0, first: 0, end: 3)])
    }

    @Test func poolingDecidesWholeGroupsOfFrames() {
        // Over groups of four the first group averages 0.9 x 0.725 and the second 0.9 x 0.2.
        let pooled = Decision(presenceThreshold: 0.5, maskThreshold: 0.5, rule: .product, pool: 4)
        let masks: [Float] = [0.9, 0.9, 0.9, 0.2, 0.2, 0.2, 0.2, 0.2]
        #expect(pooled.stretches(presence: [0.9], masks: masks, frames: 8) == [Decision.Stretch(query: 0, first: 0, end: 4)])
        #expect(Self.trained.stretches(presence: [0.9], masks: masks, frames: 8) == [Decision.Stretch(query: 0, first: 0, end: 3)])
    }

    @Test func framesAreCentredTwelveAndAHalfMillisecondsInAndEightyApart() {
        let clock = FrameClock(step: 0.08, firstCentre: 0.0125)
        let (start, end) = clock.bounds(Decision.Stretch(query: 0, first: 0, end: 3))
        #expect(start == 0)
        #expect(abs(end - (0.0125 + 0.16 + 0.04)) < 1e-9)
        let (later, _) = clock.bounds(Decision.Stretch(query: 0, first: 10, end: 11))
        #expect(abs(later - (0.0125 + 0.8 - 0.04)) < 1e-9)
    }

    @Test func speakersAreNumberedInOrderOfFirstAppearance() {
        let stretches = [
            Decision.Stretch(query: 7, first: 10, end: 20),
            Decision.Stretch(query: 2, first: 0, end: 5),
            Decision.Stretch(query: 7, first: 30, end: 31),
            Decision.Stretch(query: 2, first: 25, end: 28),
        ]
        let result = Diarization(stretches: stretches, clock: FrameClock(step: 0.08, firstCentre: 0.0125), duration: 3.0)
        #expect(result.speakerCount == 2)
        #expect(result.turns.map(\.speaker) == [0, 1, 0, 1])
        #expect(result.turns.map(\.start) == result.turns.map(\.start).sorted())
        #expect(result.turns(of: 1).count == 2)
    }
}
