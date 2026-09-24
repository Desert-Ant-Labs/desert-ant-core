import Foundation
import Testing
@_spi(AlignBindings) @testable import Align
import TestSupport

struct OverlapGolden: Decodable {
    struct Word: Decodable { let text: String?; let start: Double; let end: Double; let refined: Bool? }
    struct Case: Decodable { let name: String; let input: [Word]; let output: [Word]; let expected: [Word] }
    let cases: [Case]
}

func loadOverlapGolden() throws -> OverlapGolden {
    let url = Bundle.module.url(forResource: "overlap_golden", withExtension: "json")!
    return try JSONDecoder().decode(OverlapGolden.self, from: Data(contentsOf: url))
}

/// Wherever `input` has a word end at or before the next one starts, `output` does too, and refined words are not empty.
func expectOrdered(_ output: [WordTiming], input: [WordTiming], sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(output.count == input.count, sourceLocation: sourceLocation)
    for i in output.indices.dropLast() where input[i].end <= input[i + 1].start {
        #expect(output[i].end <= output[i + 1].start, "words \(i) and \(i + 1) overlap", sourceLocation: sourceLocation)
    }
    for (i, w) in output.enumerated() where w.refined {
        #expect(w.start < w.end, "refined word \(i) is empty", sourceLocation: sourceLocation)
    }
    for (i, w) in output.enumerated() where !w.refined {
        #expect(w == input[i], "unrefined word \(i) does not carry its input times", sourceLocation: sourceLocation)
    }
}

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Suite struct OverlapTests {
    @Test func matchesThePythonReferenceExactly() throws {
        let golden = try loadOverlapGolden()
        #expect(golden.cases.count > 60)
        for c in golden.cases {
            let input = c.input.map { WordTiming(text: $0.text ?? "", start: $0.start, end: $0.end) }
            let output = zip(input, c.output).map {
                WordTiming(text: $0.text, start: $1.start, end: $1.end, refined: $1.refined ?? false)
            }
            let expected = zip(input, c.expected).map {
                WordTiming(text: $0.text, start: $1.start, end: $1.end, refined: $1.refined ?? false)
            }
            #expect(Align.resolvingOverlaps(output, input: input) == expected, "\(c.name)")
        }
    }

    @Test func fixtureCoversEveryResolution() throws {
        let golden = try loadOverlapGolden()
        let named = Dictionary(uniqueKeysWithValues: golden.cases.map { ($0.name, $0) })
        let met = try #require(named["both refined cross at a shared seam meet at the midpoint"])
        #expect(met.expected[0].end == met.expected[1].start)
        #expect(met.expected[0].end == (met.output[0].end + met.output[1].start) / 2)
        let clamped = try #require(named["refined left word is clamped to an unrefined right neighbor"])
        #expect(clamped.expected[0].end == clamped.input[1].start && clamped.expected[0].refined == true)
        let reverted = try #require(named["a short word squeezed empty reverts and its neighbors clamp to it"])
        #expect(reverted.expected[1].refined == false && reverted.expected[0].end == reverted.input[1].start)
        for name in ["seams with a gap are untouched", "input that already overlaps is left as is",
                     "unordered input keeps its order relation"] {
            let c = try #require(named[name])
            #expect(c.expected.map(\.start) == c.output.map(\.start) && c.expected.map(\.end) == c.output.map(\.end), "\(name)")
        }
    }

    @Test func randomSequencesKeepTheInputOrderAndAreIdempotent() {
        var rng = SplitMix64(state: 20_260_924)
        for _ in 0..<500 {
            var input: [WordTiming] = [], output: [WordTiming] = []
            var t = 0.0
            for k in 0..<Int.random(in: 1...60, using: &rng) {
                let start = t + (Double.random(in: 0..<1, using: &rng) < 0.8 ? 0 : Double.random(in: -0.1...0.3, using: &rng))
                let end = start + Double.random(in: 0.01...0.5, using: &rng)
                input.append(WordTiming(text: "w\(k)", start: start, end: end))
                let refined = Double.random(in: 0..<1, using: &rng) < 0.9
                output.append(refined
                    ? WordTiming(text: "w\(k)", start: start + Double.random(in: -0.15...0.15, using: &rng),
                                 end: end + Double.random(in: -0.15...0.15, using: &rng), refined: true)
                    : input[k])
                t = end
            }
            let once = Align.resolvingOverlaps(output, input: input)
            expectOrdered(once, input: input)
            #expect(Align.resolvingOverlaps(once, input: input) == once)
            for i in input.indices where once[i].refined { #expect(output[i].refined) }
        }
    }
}

#if !os(WASI)
@Suite(.serialized, .modelBacked) struct OverlapModelTests {
    // Back-to-back words on a shared seam: the case where independent boundary estimates cross.
    @Test func refinedTranscriptKeepsSharedSeamsOrdered() async throws {
        let files = try await ModelFixture.files(AlignModel.self)
        let refiner = Align(assets: try await .align(files: files, computeUnits: .cpuOnly, revision: nil))
        let texts = "the cat sat on a mat and then it ran to the door of the old red barn by a tree".split(separator: " ")
        let words = texts.enumerated().map { i, text in
            WordTiming(text: String(text), start: 0.3 + Double(i) * 0.18, end: 0.3 + Double(i + 1) * 0.18)
        }
        let audio = synthAudio(Int((0.3 + Double(texts.count) * 0.18 + 1) * 16000), 16000)
        for language in ["en", "es"] {
            let out = try await refiner.refine(words, audio: audio, languageCode: language)
            #expect(out.contains { $0.refined }, "nothing was refined in \(language)")
            expectOrdered(out, input: words)
        }
    }
}
#endif
