import DesertAnt
import Foundation
import Testing

@testable import Voz

// The model is a download, so these cover what can be checked without it: the
// catalog declaration, the geometry contract, and the token-to-word grouping
// that produces timestamps. Anything needing the weights lives in the
// parakeet-ane repo's evaluation harness, which scores WER against a manifest.

@Test func catalogDeclaresAppleOnly() {
    #expect(VozModel.id == "voz")
    #expect(VozModel.repo == "desert-ant-labs/voz")
    #expect(VozModel.supports(.apple))
    let unsupported: [ModelPlatform] = [.android, .linux, .windows, .web]
    for platform in unsupported {
        #expect(!VozModel.supports(platform), "voz has no \(platform) backend")
    }
}

@Test func catalogShipsCompiledModelsAndSidecars() {
    let files = VozModel.files[.apple] ?? []
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
    #expect(throws: VozError.self) { try c.validate() }
}

@Test func wordsGroupOnSentencepieceBoundaries() {
    let vocab = ["\u{2581}hello", "\u{2581}wor", "ld", "<en-US>"]
    let words = timedWords(tokens: [0, 1, 2], frames: [1, 5, 7], ends: [4, 7, 9],
                           vocabulary: vocab, secondsPerFrame: 0.08, timeOffset: 0)
    #expect(words.map(\.text) == ["hello", "world"])
    // A word takes the time of the frame that emitted its first piece, and runs
    // to where its last piece ends - "world" is two pieces, so it ends where
    // "ld" does and not where "wor" does.
    #expect(abs(words[0].start - 0.08) < 1e-9)
    #expect(abs(words[0].end - 0.32) < 1e-9)
    #expect(abs(words[1].start - 0.40) < 1e-9)
    #expect(abs(words[1].end - 0.72) < 1e-9)
}

@Test func wordsSkipControlPiecesAndApplyOffset() {
    let vocab = ["\u{2581}hello", "\u{2581}wor", "ld", "<en-US>"]
    let words = timedWords(tokens: [3, 0], frames: [0, 2], ends: [0, 5],
                           vocabulary: vocab, secondsPerFrame: 0.08, timeOffset: 15.04)
    #expect(words.map(\.text) == ["hello"])
    // The offset carries the window's position in the file, on both ends.
    #expect(abs(words[0].start - (15.04 + 0.16)) < 1e-9)
    #expect(abs(words[0].end - (15.04 + 0.40)) < 1e-9)
}

@Test func wordEndsAreTrimmedToWhereTheSoundStops() {
    // A word sounding for 200 ms, then silence, inside a span the recogniser
    // claims runs for a full second. The claim is what its duration head
    // predicts; it runs to wherever the next token was picked up, so it
    // includes the pause.
    let rate = 16000.0
    var samples = [Float](repeating: 0, count: Int(rate))
    for i in 0..<Int(0.2 * rate) { samples[i] = i % 2 == 0 ? 0.5 : -0.5 }
    let claimed = [Word(text: "hello", start: 0, end: 1.0)]
    let refined = refineEnds(claimed, samples: samples[...], windowStart: 0, sampleRate: rate)
    #expect(abs(refined[0].end - 0.21) < 0.02,
            "the end should land where the sound stops, not where the model stopped looking")
    #expect(refined[0].start == 0)

    // Nothing to trim: a word sounding for its whole claimed span keeps it.
    for i in 0..<Int(rate) { samples[i] = i % 2 == 0 ? 0.5 : -0.5 }
    let full = refineEnds([Word(text: "hello", start: 0, end: 0.5)],
                          samples: samples[...], windowStart: 0, sampleRate: rate)
    #expect(abs(full[0].end - 0.5) < 0.02)

    // Silence carries no evidence, so the claim stands rather than collapsing
    // the word to zero length.
    let quiet = refineEnds([Word(text: "hello", start: 0, end: 0.5)],
                           samples: [Float](repeating: 0, count: Int(rate))[...],
                           windowStart: 0, sampleRate: rate)
    #expect(quiet[0].end == 0.5)
}

@Test func detokenizationRestoresSpacing() {
    #expect(detokenize(["\u{2581}a", "\u{2581}b", "c"]) == "a bc")
}

#endif

#if canImport(CoreML)
@Test("seam repair works in every language the model transcribes")
func seamRepairAcrossLanguages() {
    // Every language here is written in a bicameral script, which is what the
    // seam repairs depend on: a window resuming mid-sentence capitalises its
    // first word, and that is the signal. The model's other languages are all
    // bicameral too, so there is no supported language where these go blind.
    let duplicatesAtASeam = [
        ("en", "Episode", "episode"), ("de", "Folge", "folge"),
        ("fr", "Épisode", "épisode"), ("es", "Episodio", "episodio"),
        ("pl", "Odcinek", "odcinek"), ("cs", "Epizoda", "epizoda"),
        ("sv", "Avsnitt", "avsnitt"), ("hu", "Epizód", "epizód"),
        ("ru", "Эпизод", "эпизод"), ("uk", "Епізод", "епізод"),
        ("bg", "Епизод", "епизод"), ("el", "Επεισόδιο", "επεισόδιο"),
        ("de-ß", "STRASSE", "straße"),
    ]
    for (language, upper, lower) in duplicatesAtASeam {
        #expect(fold(upper) == fold(lower),
                "\(language): a window's capitalised restart must match the earlier copy")
    }

    // Folding must not go so far that it merges words that merely look alike.
    // This comparison deletes a word when it matches, so a false match at a
    // seam loses real speech.
    let distinctWords = [("fr", "résumé", "resume"), ("fr", "père", "pere"),
                         ("de", "schön", "schon"), ("el", "ή", "η"),
                         ("fr", "côte", "cote")]
    for (language, one, other) in distinctWords {
        #expect(fold(one) != fold(other),
                "\(language): distinct words must not be folded together")
    }
}
#endif
