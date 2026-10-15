import Testing
@testable import Redact

struct ChunksTests {
    private func chunks(_ s: String, _ c: Chunking) -> [String] {
        let t = UTF16Text(s)
        return Chunks.ranges(t, c).map { t.slice($0.lowerBound, $0.upperBound) }
    }

    private func sentences(_ s: String) -> [String] {
        let t = UTF16Text(s)
        return Chunks.sentences(t).map { t.slice($0.lowerBound, $0.upperBound) }
    }

    @Test func packsWholeSentencesAndCarriesOne() {
        let text = "The shipment left Rotterdam on Tuesday. Our contact there is Sophie Dubois. "
            + "She can be reached at the Prinsengracht 263 office in Amsterdam. Delivery is expected by Friday."
        #expect(chunks(text, Chunking(maxChars: 100, carry: 1)) == [
            "The shipment left Rotterdam on Tuesday. Our contact there is Sophie Dubois.",
            "Our contact there is Sophie Dubois. She can be reached at the Prinsengracht 263 office in Amsterdam.",
            "She can be reached at the Prinsengracht 263 office in Amsterdam. Delivery is expected by Friday.",
        ])
        #expect(chunks(text, Chunking(maxChars: 100, carry: 0)).count == 2)
    }

    @Test func shortTextIsOneChunk() {
        #expect(chunks("Email Anna at anna@example.com.", .default) == ["Email Anna at anna@example.com."])
        #expect(chunks("", .default).isEmpty)
    }

    @Test func titlesAndInitialsDoNotEndASentence() {
        #expect(sentences("Please call Dr. Emily Chen. She is in. Ask J. R. Smith too.") ==
            ["Please call Dr. Emily Chen.", "She is in.", "Ask J. R. Smith too."])
        #expect(sentences("Version 3.5 shipped. Done") == ["Version 3.5 shipped.", "Done"])
    }

    @Test func linesQuotesAndCJK() {
        #expect(sentences("Speaker 1: hi\nSpeaker 2: hello there") == ["Speaker 1: hi", "Speaker 2: hello there"])
        #expect(sentences("He said \"stop.\" Then he left!") == ["He said \"stop.\"", "Then he left!"])
        #expect(sentences("田中さんに会いました。明日は休みです。") == ["田中さんに会いました。", "明日は休みです。"])
    }

    @Test func longSentenceIsCutAtWords() {
        let words = (1...60).map { "word\($0)" }.joined(separator: " ")
        let out = chunks(words, Chunking(maxChars: 50, carry: 0))
        #expect(out.allSatisfy { $0.utf16.count <= 50 })
        #expect(out.joined(separator: " ") == words)
    }

    /// Every non-space character is inside some chunk, whatever the settings.
    @Test func chunksCoverTheText() {
        let text = String(repeating: "Anna met Bob at noon. ", count: 40) + "Thanks, Carl"
        let t = UTF16Text(text)
        for c in [Chunking(maxChars: 30, carry: 0), Chunking(maxChars: 100, carry: 1),
                  Chunking(maxChars: 200, carry: 2), .default] {
            var covered = Set<Int>()
            for r in Chunks.ranges(t, c) {
                #expect(r.count <= c.maxChars)
                covered.formUnion(r)
            }
            let missing = (0..<t.length).filter { !covered.contains($0) && !t.isWhitespace(at: $0) }
            #expect(missing.isEmpty, "\(c) missed \(missing.count) units")
        }
    }
}
