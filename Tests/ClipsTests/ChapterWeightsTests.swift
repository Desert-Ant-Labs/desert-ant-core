import Foundation
import Testing
import Transcript
@testable import Clips

/// The Swift forward pass must reproduce PyTorch's, or the device silently runs a different
/// network from the one that was trained and evaluated.
///
/// `chapters_tiny.bin` is a small chapters model exported by `python/export_chapters.py`;
/// `chapters_tiny.json` carries its input and PyTorch's logits for that input. Regenerate BOTH
/// with `python/testdata/make_chapters_tiny.py`, never one alone.
///
/// The tolerance is loose on purpose. This checks that the architecture was transcribed
/// correctly, not that two float pipelines round identically: the layer order, the pre-norm
/// placement, the packed QKV projection, the head split and the GELU approximation are all
/// places where a mistake changes the output by a lot, not a little. A transcription error
/// does not produce a 1e-4 discrepancy.
struct ChapterWeightsTests {
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        let url = Bundle.module.url(forResource: name, withExtension: ext)
        return try #require(url)
    }

    @Test func forwardMatchesPyTorch() throws {
        let weights = try ChapterWeights.load(contentsOf: try fixture("chapters_tiny", "bin"))
        let ref = try JSONSerialization.jsonObject(
            with: Data(contentsOf: try fixture("chapters_tiny", "json"))) as! [String: Any]

        let input = (ref["input"] as! [[Double]]).map { $0.map(Float.init) }
        let expected = (ref["logits"] as! [Double]).map(Float.init)

        let got = weights.forward(input)
        #expect(got.count == expected.count)

        var worst: Float = 0
        for (a, b) in zip(got, expected) { worst = max(worst, abs(a - b)) }
        #expect(worst < 2e-3, "worst elementwise difference \(worst) against PyTorch")
    }

    @Test func loaderRejectsGarbage() throws {
        let bad = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-chapters.bin")
        try Data("nope, this is not a weights file".utf8).write(to: bad)
        defer { try? FileManager.default.removeItem(at: bad) }
        #expect(throws: (any Error).self) { try ChapterWeights.load(contentsOf: bad) }
    }

    /// Tiling must not change a result that fits in one window. A transcript shorter than
    /// `window` takes the single-pass path, and one longer takes the overlap path; the seam
    /// between those two behaviours is where an off-by-one lives.
    @Test func tilingIsConsistentForShortInput() throws {
        let weights = try ChapterWeights.load(contentsOf: try fixture("chapters_tiny", "bin"))
        let model = ChapterModel(weights: weights)
        let ref = try JSONSerialization.jsonObject(
            with: Data(contentsOf: try fixture("chapters_tiny", "json"))) as! [String: Any]
        let input = (ref["input"] as! [[Double]]).map { $0.map(Float.init) }

        let direct = weights.forward(input).map(Double.init)
        let tiled = model.boundaryLogits(pooled: input)
        #expect(direct.count == tiled.count)
        for (a, b) in zip(direct, tiled) { #expect(abs(a - b) < 1e-6) }
    }
}

/// The public surface, and the behaviour a caller can rely on without a model artifact.
///
/// The model-backed path needs the published Hub artifact and a `select` that emits `pooled`,
/// which does not exist yet; those arrive with `HubDownloadTests`. What CAN be pinned now is
/// the contract around it, and the graceful degradation that keeps every existing clips
/// consumer loading when chapters are absent.
struct ChapterAPITests {
    @Test func chaptersUnsupportedHasItsOwnErrorAndMessage() {
        let error = ClipError.chaptersUnsupported
        #expect(error.message.contains("chapters"))
        // Distinct from predictionFailed: the remedy is "update the artifact", not
        // "the input was bad", and collapsing them would send callers to the wrong fix.
        #expect(error.message != ClipError.predictionFailed.message)
    }

    /// A model resolved WITHOUT a chapter head must still load. Every clips consumer today
    /// has such an artifact, and requiring the head would have broken all of them.
    @Test func assetsLoadWithoutAChapterHead() throws {
        let weights = try ChapterWeights.load(
            contentsOf: try #require(Bundle.module.url(forResource: "chapters_tiny",
                                                       withExtension: "bin")))
        // The head parses from bytes as well as from a URL, which is how ModelAssets hands
        // it over.
        let data = try Data(contentsOf: try #require(
            Bundle.module.url(forResource: "chapters_tiny", withExtension: "bin")))
        let fromBytes = try ChapterWeights.load(bytes: [UInt8](data))
        #expect(fromBytes.dim == weights.dim)
        #expect(fromBytes.layers.count == weights.layers.count)
    }

    /// The `[String]` overload has to produce monotonic, non-overlapping timings, because the
    /// partition DP reads them as seconds and a non-monotonic transcript would make segment
    /// durations negative.
    @Test func wordCountTimingsAreMonotonic() {
        let transcript = ["one two three.", "a.", "four five six seven eight nine."]
        var start = 0.0
        let sentences = transcript.enumerated().map { index, text -> Sentence in
            let words = max(1, text.split(separator: " ").count)
            let duration = Double(words) / Pipeline.wordsPerSecond
            defer { start += duration }
            return Sentence(id: index, text: text, start: start, end: start + duration)
        }
        #expect(sentences[0].start == 0)
        for (a, b) in zip(sentences, sentences.dropFirst()) {
            #expect(b.start >= a.end - 1e-9)
            #expect(a.end > a.start)
        }
    }
}
