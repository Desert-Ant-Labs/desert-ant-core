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

    @Test func crlfSeparatesTheTitleAndDescription() {
        let card = Titles.parse("TITLE: Cold plunges and cortisol\r\nDESC: A physiologist explains why.\r\n")
        #expect(card == Card(title: "Cold plunges and cortisol", description: "A physiologist explains why."))
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

    /// Both SDKs use the passage wording, including for text unrelated to video.
    @Test func thePromptKeepsTheClausesTheModelWasTrainedWith() {
        let p = Titles.prompt
        #expect(p.contains("{clip}"), "the substitution point must survive edits")
        #expect(p.contains("Be specific enough to identify this passage"))
        #expect(p.contains("same language as the passage"))
        #expect(p.contains("PASSAGE:"))
        #expect(!p.contains("video"), "non-video callers must not send video instructions")
    }
}

@Suite struct TitleAndroidPromptTests {
    @Test func wrapsOneUserMessageInTheGraniteTemplate() {
        #expect(Titles.androidPrompt("Café") == """
            <|start_of_role|>system<|end_of_role|>You are a helpful assistant. Please ensure responses are professional, accurate, and safe.<|end_of_text|>
            <|start_of_role|>user<|end_of_role|>Write a factual title (3-8 words) and a 1-2 sentence description for this passage.Be specific enough to identify this passage. No emoji, no hashtags, no hype.Write in the same language as the passage.

            PASSAGE:
            Café<|end_of_text|>
            <|start_of_role|>assistant<|end_of_role|>
            """)
    }

    @Test func trimsOnlyThePassageAtACharacterBoundary() throws {
        let prefix = "日本👩🏽‍🔬"
        let target = Titles.androidPrompt(prefix)
        let fitted = try Titles.fittedAndroidPrompt(prefix + " trailing text", budget: target.utf8.count) {
            $0.utf8.count
        }
        #expect(fitted == target)
    }

    @Test func replacesNulBeforeCountingTokens() throws {
        let fitted = try Titles.fittedAndroidPrompt("a\0b", budget: 1_280) {
            #expect(!$0.utf8.contains(0))
            return $0.utf8.count
        }
        #expect(fitted == Titles.androidPrompt("a\u{FFFD}b"))
    }

    @Test func boundsTokenizationForLargePassages() throws {
        let text = String(repeating: "a", count: 100_000)
        let emptyPromptSize = Titles.androidPrompt("").utf8.count
        let fitted = try Titles.fittedAndroidPrompt(text, budget: emptyPromptSize + 1_000) { prompt in
            #expect(prompt.utf8.count <= emptyPromptSize + 1_024)
            return prompt.utf8.count
        }
        #expect(fitted == Titles.androidPrompt(String(text.prefix(1_000))))
    }
}
