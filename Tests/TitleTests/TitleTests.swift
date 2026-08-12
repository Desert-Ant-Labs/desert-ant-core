import Foundation
import Testing
@testable import Title

/// Parsing the model's reply, which is the part that fails quietly.
///
/// Generation needs a ~280 MB MLX folder and a GPU, so it is not tested here. `parse` is pure
/// and is where a format drift shows up, so it is where the tests are. The design rule being
/// pinned: **a card model that drifts off format must degrade to a usable title rather than
/// throw**, because the clip is still good and selection is what ships.
@Suite struct TitleParsingTests {

    @Test func theTrainedFormatParses() {
        let card = Titles.parse("TITLE: Cold plunges and cortisol\nDESC: A physiologist explains why.")
        #expect(card.title == "Cold plunges and cortisol")
        #expect(card.description == "A physiologist explains why.")
        #expect(!card.isEmpty)
    }

    /// The training data uses `DESC`, but base-model habits leak `DESCRIPTION` through. Both
    /// are accepted, and that is a deliberate tolerance rather than an oversight.
    @Test func bothSpellingsOfDescriptionAreAccepted() {
        let short = Titles.parse("TITLE: A\nDESC: one")
        let long = Titles.parse("TITLE: A\nDESCRIPTION: one")
        #expect(short.description == "one")
        #expect(long.description == "one", "base models leak the longer spelling")
    }

    /// Labels are case-insensitive because a small instruct model lowercases them under
    /// unusual input, and losing a good title to that would be absurd.
    @Test func labelsAreCaseInsensitive() {
        let card = Titles.parse("title: Lowercase label\ndesc: still parsed")
        #expect(card.title == "Lowercase label")
        #expect(card.description == "still parsed")
    }

    /// No labels at all: take the first real line as the title rather than returning nothing.
    /// This is the degradation path, and it is the reason `parse` does not throw.
    @Test func anUnlabelledReplyStillYieldsATitle() {
        let card = Titles.parse("Cold plunges and cortisol\n")
        #expect(card.title == "Cold plunges and cortisol")
        #expect(card.description.isEmpty)
        #expect(!card.isEmpty, "a title alone is still a usable card")
    }

    /// Empty is the ONLY failure signal a caller gets, so it must be reachable and honest.
    @Test func anEmptyReplyIsAnEmptyCard() {
        #expect(Titles.parse("").isEmpty)
        #expect(Titles.parse("\n   \n").isEmpty)
    }

    /// Whitespace around the label and the value is stripped, including a leading blank line,
    /// which the model emits often enough to matter.
    @Test func surroundingWhitespaceIsStripped() {
        let card = Titles.parse("\n  TITLE:   Spaced out  \n  DESC:   and trimmed  \n")
        #expect(card.title == "Spaced out")
        #expect(card.description == "and trimmed")
    }

    /// A colon inside the value must survive: titles legitimately contain them, and splitting
    /// on the first colon rather than the label prefix would truncate them.
    @Test func aColonInsideTheValueSurvives() {
        let card = Titles.parse("TITLE: Sleep: the short version\nDESC: Ten minutes on it.")
        #expect(card.title == "Sleep: the short version")
    }

    /// The prompt is the trained wording and a paraphrase is a different task to the model, so
    /// its load-bearing parts are pinned. This is not style policing: before the two negative
    /// rules existed, every sample opened "The video discusses…".
    @Test func thePromptKeepsTheClausesTheModelWasTrainedWith() {
        let p = Titles.prompt
        #expect(p.contains("{clip}"), "the substitution point must survive edits")
        #expect(p.contains("SPECIFIC ENOUGH TO IDENTIFY THIS CLIP"))
        #expect(p.contains("NEVER begin with"))
        #expect(p.contains("SAME LANGUAGE"))
        #expect(p.contains("TITLE:") && p.contains("DESC:"),
                "the reply format the parser expects")
    }
}
