import Foundation
import Testing
@testable import Voz

// The vocabulary bias through the real decode loop, with a scripted engine that
// hands over raw logits (so the bias applies) and makes its choices from what
// the pipeline feeds it: the previous token (through the embedding), the frame
// (through the encoder output) and the recurrent state. Rolling back has to
// restore all three, so a slip in any of them changes the transcript.

private let pieces = ["▁So", "▁Soph", "F", "i", "ie", "▁X"]
private enum T { static let so = 0, soph = 1, f = 2, i = 3, ie = 4, poison = 5, blank = 6 }

/// The same 15 s window as the other engine tests; it decodes to two frames.
private let geometry = """
{"sample_rate":16000,"hop_length":160,"n_samples":240000,"n_rows":12,"n_mels":2,
 "n_fft":160,"preemph":0.97,"n_padded_samples":240480,"valid_frames":11,
 "enc_frames":4,"joint_hidden":2,"pred_hidden":2,"pred_layers":1,
 "vocab_size":6,"blank_idx":6,"durations":[0,1],"decode_width":2}
"""

private final class ScriptedEngine: Engine, @unchecked Sendable {
    enum After { case hybrid, phrase }
    let decodeLanes = 1
    let encodeBatch = 1
    let encodeDepth = 1
    let reducesInGraph = false
    let decodeRunsBesideEncoder = false
    /// After "▁So": the model wants "ie" ("Soie", a hybrid), or "F" "i" (SoFi).
    let after: After
    /// The frame the word starts at: 0, or 1, the last frame of the window.
    let startFrame: Int
    private(set) var poisoned = 0

    init(after: After, startFrame: Int) { self.after = after; self.startFrame = startFrame }

    func encode(slot: Int, lanes: Int, buffers: PipelineBuffers,
                isolation: isolated (any Actor)?) async throws {
        // Channel 0 of the encoder output carries the frame index.
        let out = buffers.slots[slot].encOut.ptr
        for lane in 0..<lanes {
            for t in 0..<4 {
                out[lane * 8 + t] = Element(Float(t))
                out[lane * 8 + 4 + t] = 0
            }
        }
    }

    func runDecodeStep(embed: Buffer, hIn: Buffer, cIn: Buffer, encStep: Buffer,
                       logits: Buffer, tok: inout [Int32], dur: inout [Int32],
                       hOut: Buffer, cOut: Buffer, activeLanes: [Int],
                       isolation: isolated (any Actor)?) async throws {
        let width = 2, count = 6 + 1 + 2
        for lane in activeLanes {
            // The embedding row of token k is [k, 0]: the previous token.
            let previous = Int(Float(embed.ptr[lane * 2]).rounded())
            // The recurrent state counts the tokens written in this window.
            let written = Int(Float(hIn.ptr[lane * 2]).rounded())
            hOut.ptr[lane * 2] = Element(Float(written + 1))
            hOut.ptr[lane * 2 + 1] = 0
            cOut.ptr[lane * 2] = cIn.ptr[lane * 2]
            cOut.ptr[lane * 2 + 1] = cIn.ptr[lane * 2 + 1]
            let base = logits.ptr + lane * count * width
            for offset in 0..<width {
                let frame = Int(Float(encStep.ptr[(lane * 2) * width + offset]).rounded())
                var scores = [Float](repeating: -20, count: 7)
                switch previous {
                case T.blank where written != 0:
                    // A restored lane sees no tokens written: anything else
                    // means the recurrent state was not restored.
                    scores[T.poison] = 10; poisoned += 1
                case T.blank where frame == startFrame:
                    scores[T.soph] = 10
                    scores[T.so] = 8          // within reach of the bias, not of the model
                case T.so:
                    if after == .hybrid { scores[T.ie] = 10 } else { scores[T.f] = 10 }
                case T.f: scores[T.i] = 10
                case T.soph: scores[T.ie] = 10
                default: scores[T.blank] = 10
                }
                for k in 0..<7 { base[k * width + offset] = Element(scores[k]) }
                // A word's first token moves on a frame; the rest of it, and a
                // blank (which always moves on), stay put.
                let firstOfWord = previous == T.blank
                base[7 * width + offset] = Element(Float(firstOfWord ? 0 : 1))    // 0 frames
                base[8 * width + offset] = Element(Float(firstOfWord ? 1 : 0))    // 1 frame
            }
        }
    }
}

private func transcribe(_ engine: ScriptedEngine, vocabulary: [String],
                        seconds: Int = 15) async throws -> Voz.Result {
    // embedding.f16 is float16 on every platform, whatever the runtime's buffer
    // type (Float where Core ML is absent). Small integers, written as bits.
    func half(_ n: Int) -> UInt16 {
        guard n > 0 else { return 0 }
        let e = Int.bitWidth - 1 - n.leadingZeroBitCount
        return UInt16((e + 15) << 10 | ((n << 10) >> e) & 0x3FF)
    }
    var table = [UInt16](repeating: 0, count: (pieces.count + 1) * 2)
    for k in 0...pieces.count { table[k * 2] = half(k).littleEndian }
    let embedding = table.withUnsafeBytes { Data($0) }
    let vocab = try JSONSerialization.data(withJSONObject: pieces)
    let assets = try Assets(meta: Data(geometry.utf8), vocab: vocab, embeddingBytes: embedding)
    let buffers = try PipelineBuffers(configuration: assets.configuration, lanes: 1,
                                      batch: engine.encodeBatch, depth: engine.encodeDepth)
    let voz = Voz(assets: assets, engine: engine, buffers: buffers)
    return try await voz.transcribe(samples: [Float](repeating: 0.1, count: 16000 * seconds),
                                    vocabulary: vocabulary)
}

private func same(_ a: Voz.Result, _ b: Voz.Result) -> Bool {
    a.text == b.text && a.words.map { [$0.text, "\($0.start)", "\($0.end)"] }
        == b.words.map { [$0.text, "\($0.start)", "\($0.end)"] }
}

@Suite("Vocabulary bias in the decode loop")
struct DecoderBoostTests {
    @Test func theBiasWritesAPhraseTheModelFinishes() async throws {
        let plain = try await transcribe(ScriptedEngine(after: .phrase, startFrame: 0), vocabulary: [])
        let biased = try await transcribe(ScriptedEngine(after: .phrase, startFrame: 0),
                                          vocabulary: ["SoFi"])
        #expect(plain.text == "Sophie")
        #expect(biased.text == "SoFi")
    }

    @Test func anAbandonedWordRollsBackToTheModelsOwnTranscript() async throws {
        let engine = ScriptedEngine(after: .hybrid, startFrame: 0)
        let plain = try await transcribe(ScriptedEngine(after: .hybrid, startFrame: 0), vocabulary: [])
        let biased = try await transcribe(engine, vocabulary: ["SoFi"])
        // "▁So" then "ie" would be "Soie": the decoder goes back, decides frame 0
        // without the bias, and ends where the model would have on its own,
        // timestamps included.
        #expect(biased.text == "Sophie")
        #expect(same(biased, plain))
        #expect(engine.poisoned == 0, "the recurrent state must be restored with the rest")
    }

    @Test func aWordOpenAtTheEndOfTheWindowRollsBack() async throws {
        let plain = try await transcribe(ScriptedEngine(after: .phrase, startFrame: 1), vocabulary: [])
        let engine = ScriptedEngine(after: .phrase, startFrame: 1)
        let biased = try await transcribe(engine, vocabulary: ["SoFi"])
        // "▁So" lands on the last frame and the window ends before "F": the lane
        // replays that frame without the bias rather than retire with "So".
        #expect(!biased.text.contains("So "))
        #expect(biased.text != "So")
        #expect(same(biased, plain))
        #expect(engine.poisoned == 0)
        // A complete one-word phrase on the last frame is kept.
        let whole = try await transcribe(ScriptedEngine(after: .phrase, startFrame: 1),
                                         vocabulary: ["So"])
        #expect(whole.text == "So")
    }

    @Test func aLaneReusedForTheNextWindowStartsClean() async throws {
        // Two windows through one lane: the second starts from a fresh state
        // and its own bias decisions, not the first window's.
        let engine = ScriptedEngine(after: .hybrid, startFrame: 0)
        let plain = try await transcribe(ScriptedEngine(after: .hybrid, startFrame: 0),
                                         vocabulary: [], seconds: 28)
        let biased = try await transcribe(engine, vocabulary: ["SoFi"], seconds: 28)
        #expect(same(biased, plain))
        #expect(engine.poisoned == 0)
    }
}
