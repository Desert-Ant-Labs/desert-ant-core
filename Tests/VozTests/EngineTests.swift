#if canImport(CoreML)
import Foundation
import Testing
@testable import Voz

// The seam the browser and the Neural Engine share, tested with an engine that
// is neither: the pipeline's ownership of its buffers does not depend on which
// runtime is underneath, and that is the part a wasm host cannot check for us.

// Real window length, toy tensors: the boundary search looks three seconds
// back from a window's end, so a window has to be longer than that even when
// the model behind it is a stub.
private let smallGeometry = """
{"sample_rate":16000,"hop_length":160,"n_samples":240000,"n_rows":12,"n_mels":2,
 "n_fft":160,"preemph":0.97,"n_padded_samples":240480,"valid_frames":11,
 "enc_frames":2,"joint_hidden":2,"pred_hidden":2,"pred_layers":1,
 "vocab_size":1,"blank_idx":1,"durations":[1],"decode_width":2}
"""

private let configuration = try! JSONDecoder().decode(
    Configuration.self, from: Data(smallGeometry.utf8))

private final class TestEngine: Engine, @unchecked Sendable {
    let decodeLanes = 1
    let encodeDepth: Int
    var active = 0
    var peak = 0
    var failNext = false

    init(encodeDepth: Int = 1) { self.encodeDepth = encodeDepth }

    func encode(slot: Int, buffers: PipelineBuffers,
                isolation: isolated (any Actor)?) async throws {
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        // Suspends where a real dispatch does, which is where two
        // transcriptions used to interleave into one set of buffers.
        try await Task.sleep(nanoseconds: 1_000_000)
        if failNext {
            failNext = false
            throw VozError.invalidModel("test failure")
        }
    }
    func runDecodeStep(embed: Buffer, hIn: Buffer, cIn: Buffer, encStep: Buffer,
                       logits: Buffer, hOut: Buffer, cOut: Buffer,
                       isolation: isolated (any Actor)?) async throws {
        // Blank everywhere, so the decode ends the window rather than emitting.
        logits.zero()
        logits.ptr[configuration.blankIdx * configuration.decodeWidth] = 1
    }
}

@Test func aTranscriptionOwnsThePipelineUntilItsLastAwait() async throws {
    let assets = try Assets(meta: Data(smallGeometry.utf8), vocab: Data("[\"word\"]".utf8),
                            embeddingBytes: Data(repeating: 0, count: 8))
    let engine = TestEngine()
    let buffers = try PipelineBuffers(configuration: assets.configuration, lanes: 1,
                                      depth: engine.encodeDepth)
    let voz = Voz(assets: assets, engine: engine, buffers: buffers)

    // A failed run must release the pipeline rather than wedge it.
    engine.failNext = true
    await #expect(throws: VozError.self) {
        try await voz.transcribe(samples: [Float](repeating: 0, count: 240_000))
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<4 {
            group.addTask {
                _ = try await voz.transcribe(samples: [Float](repeating: 0, count: 240_000))
            }
        }
        try await group.waitForAll()
    }
    #expect(engine.peak == 1, "two transcriptions must never share the buffers")
}

/// An engine that finishes windows in the wrong order on purpose.
private final class ShuffledEngine: Engine, @unchecked Sendable {
    let decodeLanes = 1
    let encodeDepth = 4
    private let lock = NSLock()
    private var _order: [Int] = []
    var order: [Int] { lock.lock(); defer { lock.unlock() }; return _order }

    private func note(_ slot: Int) { lock.lock(); _order.append(slot); lock.unlock() }

    func encode(slot: Int, buffers: PipelineBuffers,
                isolation: isolated (any Actor)?) async throws {
        // Later slots return first, which is what a runtime placing requests
        // over two engines does to a pipeline that assumes arrival order.
        try await Task.sleep(nanoseconds: UInt64(4 - slot) * 2_000_000)
        note(slot)
    }

    func runDecodeStep(embed: Buffer, hIn: Buffer, cIn: Buffer, encStep: Buffer,
                       logits: Buffer, hOut: Buffer, cOut: Buffer,
                       isolation: isolated (any Actor)?) async throws {
        logits.zero()
        logits.ptr[configuration.blankIdx * configuration.decodeWidth] = 1
    }
}

@Test func windowsReachTheDecodeInOrderHoweverTheyLand() async throws {
    let assets = try Assets(meta: Data(smallGeometry.utf8), vocab: Data("[\"word\"]".utf8),
                            embeddingBytes: Data(repeating: 0, count: 8))
    let engine = ShuffledEngine()
    let buffers = try PipelineBuffers(configuration: assets.configuration, lanes: 1,
                                      depth: engine.encodeDepth)
    let voz = Voz(assets: assets, engine: engine, buffers: buffers)
    // Enough audio for several windows, so the encodes genuinely overlap.
    // Four windows of audio, so the encodes genuinely overlap at depth four.
    _ = try await voz.transcribe(samples: [Float](repeating: 0, count: 960_000))
    #expect(engine.order.count > 1, "the encodes should have overlapped")
    #expect(engine.order != engine.order.sorted(), "and finished out of order")
}
#endif
