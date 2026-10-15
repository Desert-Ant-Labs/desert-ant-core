import Foundation
import Testing
@testable import Voz

/// The vocabulary bias (``Booster``) on a toy vocabulary: which tokens earn a
/// bonus, which do not, and what it leaves for the next token.
@Suite("Booster")
struct BoostTests {
    // ids:          0       1       2      3     4    5    6     7      8       9       10
    let vocab = ["▁So", "▁Soph", "F", "i", "ph", "ie", "▁and", "▁And", "▁The", "▁Home", "▁Seiko.",
    //             11       12   13    14         15          16   17    18     19     20
                 "▁SoFi", "e", ",", "▁Seiko", "▁McDonald", "'", "s", "▁St", ".", "▁Jude"]

    func booster(_ phrases: [String]) -> Booster {
        Booster(phrases: phrases, vocabulary: vocab, startBonus: 2.5, continueBonus: 4,
                partialBonus: 1, margin: 6)!
    }

    @Test func finishingAWordEarnsTheMostAndAnyTokenSplitWorks() {
        let b = booster(["SoFi"])
        let start = b.step([], token: 0)              // "▁So": inside the first word
        #expect(start.bonus == 1 && !start.finishedWord && start.next.count == 1)
        let f = b.step(start.next, token: 2)          // "F": still inside
        #expect(f.bonus == 1 && f.continued && !f.finishedWord)
        let i = b.step(f.next, token: 3)              // "i": finishes "SoFi"
        #expect(i.bonus == 4 && i.continued && i.finishedWord)
        let ph = b.step(start.next, token: 4)         // "ph": leaves the phrase
        #expect(ph.bonus == 0 && !ph.continued && !ph.finishedWord)
    }

    @Test func recasingTheModelsOwnWordEarnsNothing() {
        let b = booster(["Android"])
        #expect(b.step([], token: 7, chosen: 6).bonus == 0)   // "▁And" over "▁and"
        #expect(b.step([], token: 7, chosen: 0).bonus == 1)   // "▁And" over something else
    }

    @Test func aCommonFirstWordIsNotBoostedButTheRestIs() {
        let b = booster(["The Home Depot"])
        let the = b.step([], token: 8)                // "▁The": a whole first word
        #expect(the.bonus == 0 && the.finishedWord)
        let home = b.step(the.next, token: 9)         // "▁Home": finishes the second word
        #expect(home.bonus == 4 && home.continued)
    }

    @Test func aWholeOneWordPhraseWithPunctuation() {
        let b = booster(["Seiko"])
        let s = b.step([], token: 10)                 // "▁Seiko." completes it
        #expect(s.bonus == 2.5 && s.finishedWord && s.next.isEmpty)
    }

    @Test func casingMatters() {
        #expect(booster(["sofi"]).step([], token: 0).bonus == 0)
    }

    @Test func emptyListsMakeNoBooster() {
        #expect(Booster(phrases: ["", "  "], vocabulary: vocab) == nil)
    }

    /// Walk `tokens` from a word the bias started at the first one, and give
    /// the verdict the decoder would reach (`nil`: the next token is still
    /// `pending`; the last entry: at the end of the audio).
    func verdicts(_ b: Booster, _ tokens: [Int]) -> [Booster.Verdict] {
        let first = b.step([], token: tokens[0])
        var state = first.next, atEnd = first.finishedWord
        var out: [Booster.Verdict] = []
        for t in tokens.dropFirst() {
            let step = b.step(state, token: t)
            let v = b.verdict(after: t, step, atWordEnd: atEnd)
            out.append(v)
            if v != .pending { return out }
            state = step.next; atEnd = step.finishedWord
        }
        out.append(b.verdictAtEnd(atWordEnd: atEnd))
        return out
    }

    @Test func aCompletedPhraseIsNotDoneUntilTheWordEnds() {
        let b = booster(["SoFi"])
        // One token: "▁SoFi" then "e" is the word "SoFie", not SoFi.
        #expect(verdicts(b, [11, 12]) == [.abandoned])
        #expect(verdicts(b, [11, 13]) == [.confirmed])            // "SoFi,"
        #expect(verdicts(b, [11, 6]) == [.confirmed])             // "SoFi and"
        #expect(verdicts(b, [11]) == [.confirmed])                // the audio ends
        // Three tokens: the same, after "▁So" "F" "i".
        #expect(verdicts(b, [0, 2, 3, 12]) == [.pending, .pending, .abandoned])
        #expect(verdicts(b, [0, 2, 3, 13]) == [.pending, .pending, .confirmed])
    }

    @Test func aWordCutOffByTheEndOfTheAudioIsAbandoned() {
        let b = booster(["SoFi"])
        #expect(verdicts(b, [0]) == [.abandoned])                 // "▁So", then nothing
        #expect(verdicts(b, [0, 2]) == [.pending, .abandoned])    // "▁So" "F", then nothing
    }

    @Test func anotherPhraseDoesNotHideAnAbandonedWord() {
        let b = booster(["SoFi", "Seiko"])
        // "▁So" then "▁Seiko" completes Seiko but leaves "So" unfinished.
        #expect(verdicts(b, [0, 14]) == [.abandoned])
        #expect(verdicts(b, [0, 4]) == [.abandoned])              // "▁So" "ph": left the phrase
    }

    @Test func punctuationInsideAPhraseCarriesItOn() {
        let b = booster(["McDonald's", "St. Jude"])
        // "▁McDonald" "'" "s", then the next word.
        #expect(verdicts(b, [15, 16, 17, 6]) == [.pending, .pending, .confirmed])
        // "▁St" "." "▁Jude": the first word ends at its "." and the phrase goes on.
        #expect(verdicts(b, [18, 19, 20]) == [.pending, .confirmed])
        // Punctuation the phrase does not have still closes an unfinished word.
        #expect(verdicts(b, [15, 13]) == [.abandoned])
    }
}
