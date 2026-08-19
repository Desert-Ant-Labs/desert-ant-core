import DesertAnt
import Foundation
import Testing

@testable import Scribe

// The model is a download, so these cover what can be checked without it: the
// catalog declaration, the geometry contract, and the token-to-word grouping
// that produces timestamps. Anything needing the weights lives in the
// parakeet-ane repo's evaluation harness, which scores WER against a manifest.

@Test func catalogDeclaresAppleOnly() {
    #expect(ScribeModel.id == "scribe")
    #expect(ScribeModel.repo == "desert-ant-labs/scribe")
    #expect(ScribeModel.supports(.apple))
    let unsupported: [ModelPlatform] = [.android, .linux, .windows, .web]
    for platform in unsupported {
        #expect(!ScribeModel.supports(platform), "scribe has no \(platform) backend")
    }
}

@Test func catalogShipsCompiledModelsAndSidecars() {
    let files = ScribeModel.files[.apple] ?? []
    // Compiled programs are directories on the Hub, hence the trailing slash.
    #expect(files.contains("encoder.mlmodelc/"))
    #expect(files.contains("mel.mlmodelc/"))
    #expect(files.contains("decoder.mlmodelc/"))
    #expect(files.contains("meta.json"))
    #expect(files.contains("vocab.json"))
    #expect(files.contains("embedding.f16"))
    // An .mlpackage would silently cost ~127x on every load.
    #expect(!files.contains { $0.hasSuffix(".mlpackage/") })
}

#if canImport(CoreML)

private let geometry = """
{"sample_rate":16000,"hop_length":160,"n_samples":240000,"n_rows":1503,"n_mels":128,
 "n_fft":512,"preemph":0.97,"n_padded_samples":240480,"valid_frames":1500,
 "enc_frames":188,"joint_hidden":640,"pred_hidden":640,"pred_layers":2,
 "vocab_size":8192,"blank_idx":8192,"durations":[0,1,2,3,4],"decode_width":8}
"""

@Test func configurationDecodesAndValidates() throws {
    let c = try JSONDecoder().decode(Configuration.self, from: Data(geometry.utf8))
    try c.validate()
    // One encoder frame is 80 ms: the resolution of every word time.
    #expect(abs(c.secondsPerFrame - 0.08) < 1e-9)
}

@Test func configurationRejectsImpossibleGeometry() throws {
    let broken = geometry.replacingOccurrences(of: "\"enc_frames\":188", with: "\"enc_frames\":0")
    let c = try JSONDecoder().decode(Configuration.self, from: Data(broken.utf8))
    #expect(throws: ScribeError.self) { try c.validate() }
}

@Test func wordsGroupOnSentencepieceBoundaries() {
    let vocab = ["\u{2581}hello", "\u{2581}wor", "ld", "<en-US>"]
    let words = timedWords(tokens: [0, 1, 2], frames: [1, 5, 7],
                           vocabulary: vocab, secondsPerFrame: 0.08, timeOffset: 0)
    #expect(words.map(\.text) == ["hello", "world"])
    // A word takes the time of the frame that emitted its first piece.
    #expect(abs(words[0].start - 0.08) < 1e-9)
    #expect(abs(words[1].start - 0.40) < 1e-9)
}

@Test func wordsSkipControlPiecesAndApplyOffset() {
    let vocab = ["\u{2581}hello", "\u{2581}wor", "ld", "<en-US>"]
    let words = timedWords(tokens: [3, 0], frames: [0, 2],
                           vocabulary: vocab, secondsPerFrame: 0.08, timeOffset: 15.04)
    #expect(words.map(\.text) == ["hello"])
    // The offset carries the window's position in the file.
    #expect(abs(words[0].start - (15.04 + 0.16)) < 1e-9)
}

@Test func detokenizationRestoresSpacing() {
    #expect(detokenize(["\u{2581}a", "\u{2581}b", "c"]) == "a bc")
}

#endif
