#if canImport(CoreML)
import Foundation
import Testing
@testable import Voz

private let geometry = """
{"sample_rate":16000,"hop_length":160,"n_samples":240000,"n_rows":1503,"n_mels":2,
 "n_fft":512,"preemph":0.97,"n_padded_samples":240480,"valid_frames":1500,
 "enc_frames":188,"joint_hidden":2,"pred_hidden":2,"pred_layers":1,
 "vocab_size":1,"blank_idx":1,"durations":[0,1],"decode_width":8}
"""

private final class FrameEngine: Engine, @unchecked Sendable {
    let decodeLanes = 1
    let encodeBatch = 1
    let encodeDepth = 1
    let reducesInGraph = true
    let decodeRunsBesideEncoder = false
    let delay: UInt64

    init(delay: UInt64) { self.delay = delay }

    func encode(slot: Int, lanes: Int, buffers: PipelineBuffers,
                isolation: isolated (any Actor)?) async throws {
        try await Task.sleep(nanoseconds: delay)
    }

    func runDecodeStep(embed: Buffer, hIn: Buffer, cIn: Buffer, encStep: Buffer,
                       logits: Buffer, tok: inout [Int32], dur: inout [Int32],
                       hOut: Buffer, cOut: Buffer, activeLanes: [Int],
                       isolation: isolated (any Actor)?) async throws {
        tok = [Int32](repeating: 0, count: 8)
        dur = [Int32](repeating: 1, count: 8)
    }
}

private func makeVoz(delay: UInt64) throws -> Voz {
    let assets = try Assets(meta: Data(geometry.utf8), vocab: Data("[\"▁w\"]".utf8),
                            embeddingBytes: Data(repeating: 0, count: 8))
    let engine = FrameEngine(delay: delay)
    let buffers = try PipelineBuffers(configuration: assets.configuration, lanes: 1,
                                      batch: engine.encodeBatch, depth: engine.encodeDepth)
    return Voz(assets: assets, engine: engine, buffers: buffers)
}

private func finalUpdate(_ live: LiveTranscriber) async -> Voz.LiveUpdate? {
    var last: Voz.LiveUpdate?
    for await update in live.updates { last = update }
    return last
}

@Suite("LiveTranscriber")
struct LiveTests {
    @Test func finishDuringAPassKeepsTheAudioAppendedMeanwhile() async throws {
        let voz = try makeVoz(delay: 50_000_000)
        let audio = [Float](repeating: 0.1, count: 16_000 * 8)
        let expected = try await voz.transcribe(samples: audio).words.count
        let live = voz.liveTranscriber()
        for start in stride(from: 0, to: audio.count, by: 1600) {
            await live.append(Array(audio[start..<Swift.min(start + 1600, audio.count)]),
                              sampleRate: 16_000)
        }
        await live.finish()
        let last = await finalUpdate(live)
        #expect(last?.isFinal == true)
        #expect(last?.committedWords.count == expected)
    }

    @Test func finishWithNoPassRunningTranscribesEverything() async throws {
        let voz = try makeVoz(delay: 0)
        let audio = [Float](repeating: 0.1, count: 16_000 * 3)
        let expected = try await voz.transcribe(samples: audio).words.count
        let live = voz.liveTranscriber()
        await live.append(audio, sampleRate: 16_000)
        try await Task.sleep(nanoseconds: 200_000_000)
        await live.finish()
        let last = await finalUpdate(live)
        #expect(last?.isFinal == true)
        #expect(last?.committedWords.count == expected)
    }
}
#endif
