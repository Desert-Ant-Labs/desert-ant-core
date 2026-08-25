import Testing

@testable import Ear

/// What a caller is allowed to conclude from an answer.
struct DetectionTests {
    static func detection(_ pairs: [(String, Double)], windows: Int = 3) -> Detection {
        Detection(candidates: pairs.map { LanguagePrediction(language: $0.0, probability: $0.1) },
                  windows: windows)
    }

    @Test func reportsTheTopCandidate() {
        let d = Self.detection([("pt", 0.91), ("es", 0.05)])
        #expect(d.language == "pt")
        #expect(abs(d.confidence - 0.91) < 1e-9)
    }

    @Test func nothingHeardIsNotAnAnswer() {
        let d = Self.detection([], windows: 0)
        #expect(d.language == nil)
        #expect(d.confidence == 0)
        #expect(!d.isReliable)
    }

    @Test func aClearWinnerIsReliable() {
        #expect(Self.detection([("de", 0.88), ("nl", 0.04)]).isReliable)
    }

    @Test func aNarrowWinIsNotReliable() {
        // Two candidates this close are a coin toss dressed as an answer.
        #expect(!Self.detection([("es", 0.44), ("gl", 0.40)]).isReliable)
    }

    @Test func theMarginIsTheCalibratedOne() {
        // 0.25 was swept against 162 recordings: 98.5% of answers above it route
        // correctly, against 95.2% at the 0.15 that was here before it was
        // measured. Changing it means re-running that sweep, not re-guessing.
        #expect(Detection.reliableMargin == 0.25)
        #expect(!Self.detection([("de", 0.50), ("nl", 0.30)]).isReliable)  // 0.20
        #expect(Self.detection([("de", 0.55), ("nl", 0.25)]).isReliable)   // 0.30
    }

    @Test func theNordicGroupIsNeverReliableHoweverConfident() {
        // The detector reads Norwegian as Swedish about 40% of the time, and it
        // does so confidently, so probability does not reveal the problem and a
        // margin test cannot catch it.
        #expect(!Self.detection([("sv", 0.99), ("en", 0.001)]).isReliable)
        #expect(!Self.detection([("no", 0.97), ("en", 0.001)]).isReliable)
        #expect(!Self.detection([("da", 0.96), ("en", 0.001)]).isReliable)
    }

    @Test func theLanguageIsStillReportedWhenUnreliable() {
        // Unreliable means "do not route work on this", not "hide it".
        let d = Self.detection([("sv", 0.99), ("en", 0.001)])
        #expect(d.language == "sv")
        #expect(d.confidence > 0.9)
    }

    // MARK: - Label space

    @Test func aliasesBecomeTheCodesCallersExpect() {
        #expect(canonicalLanguage("nb") == "no")
        #expect(canonicalLanguage("tl") == "fil")
        #expect(canonicalLanguage("yue") == "zh")
        #expect(canonicalLanguage("de") == "de")
    }

    @Test func aliasedNorwegianIsAlsoUnreliable() {
        // The alias has to be applied before the check, or the model's own code
        // for Norwegian slips past it.
        #expect(confusableLanguages.contains(canonicalLanguage("nb")))
    }
}
