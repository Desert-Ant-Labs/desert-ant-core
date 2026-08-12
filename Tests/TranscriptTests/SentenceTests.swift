import Testing
import Transcript

/// Words with the spacing a recognizer leaves on them, one word per half second.
func words(_ text: String, from start: Double = 0, step: Double = 0.5) -> [TimedWord] {
    text.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { index, word in
        TimedWord(text: index == 0 ? String(word) : " " + word,
                  start: start + Double(index) * step,
                  end: start + Double(index + 1) * step)
    }
}

struct SentenceSplitting {
    @Test func splitsOnTerminalPunctuation() {
        let sentences = Sentence.sentences(from: words("One two. Three four!"))

        #expect(sentences.count == 2)
        #expect(sentences[0].text == "One two.")
        #expect(sentences[0].start == 0)
        #expect(sentences[0].end == 1.0)
        #expect(sentences[1].text == "Three four!")
        #expect(sentences[1].start == 1.0)
        #expect(sentences[1].end == 2.0)
    }

    @Test func idsAreTranscriptPositions() {
        // Selection returns these numbers and nothing else.
        #expect(Sentence.sentences(from: words("A. B. C.")).map(\.id) == [0, 1, 2])
    }

    @Test func leadingSilence() {
        #expect(Sentence.sentences(from: words("Hello there.", from: 10)).first?.start == 10)
    }

    @Test func unpunctuatedTail() {
        let sentences = Sentence.sentences(from: words("Done. And then this"))
        #expect(sentences.count == 2)
        #expect(sentences[1].text == "And then this")
    }

    @Test func runOnIsBrokenUp() {
        #expect(Sentence.sentences(from: words(String(repeating: "word ", count: 200))).count > 1)
    }

    @Test func noSpeech() {
        #expect(Sentence.sentences(from: []).isEmpty)
        #expect(Sentence.sentences(from: words("   ")).isEmpty)
    }

    @Test func loneTerminator() {
        // Recognizers split punctuation off often enough that closing on it
        // would emit "." as an entry the model then has to score.
        let split = [TimedWord(text: "Hello", start: 0, end: 1),
                     TimedWord(text: ".", start: 1, end: 1.1),
                     TimedWord(text: " Bye.", start: 1.2, end: 2)]
        #expect(Sentence.sentences(from: split).map(\.text) == ["Hello.", "Bye."])
    }

    @Test func untimedWords() {
        let mixed = [TimedWord(text: "Placed", start: 5, end: 6),
                     TimedWord(text: " unplaced", start: -1, end: -1),
                     TimedWord(text: " end.", start: 6, end: 7)]
        let sentences = Sentence.sentences(from: mixed)

        #expect(sentences.count == 1)
        #expect(sentences[0].start == 5)
        #expect(sentences[0].end == 7)
    }
}
