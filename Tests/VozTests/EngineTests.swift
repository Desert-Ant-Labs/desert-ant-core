import Foundation
import Testing
@testable import Voz

// The seam the browser and the Neural Engine share, tested with an engine that
// is neither: the pipeline's ownership of its buffers does not depend on which
// runtime is underneath, and that is the part a wasm host cannot check for us.

private let smallGeometry = """
{"sample_rate":16000,"hop_length":160,"n_samples":1600,"n_rows":12,"n_mels":2,
 "n_fft":160,"preemph":0.97,"n_padded_samples":1760,"valid_frames":11,
 "enc_frames":2,"joint_hidden":2,"pred_hidden":2,"pred_layers":1,
 "vocab_size":1,"blank_idx":1,"durations":[1],"decode_width":2}
"""

private final class TestEngine: Engine, @unchecked Sendable {
    let decodeLanes = 1
    let encodeBatch = 3
    let reducesInGraph = true
    var active = 0
    var peak = 0
    var failNext = false

    func stage(lanes: Int) {}
    func runMel(rows: Buffer, melMask: Buffer, mel: Buffer,
                isolation: isolated (any Actor)?) async throws {}
    func runEncoder(mel: Buffer, keyBias: Buffer, padMask: Buffer, encOut: Buffer,
                    isolation: isolated (any Actor)?) async throws {
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        // Suspends where a browser's promise would, which is where two
        // transcriptions used to interleave into one set of buffers.
        try await Task.sleep(nanoseconds: 1_000_000)
        if failNext {
            failNext = false
            throw VozError.invalidModel("test failure")
        }
    }
    func runDecodeStep(embed: Buffer, hIn: Buffer, cIn: Buffer, encStep: Buffer,
                       logits: Buffer, tok: inout [Int32], dur: inout [Int32],
                       hOut: Buffer, cOut: Buffer,
                       isolation: isolated (any Actor)?) async throws {
        tok = [1, 1]
        dur = [0, 0]
    }
}

@Test func aTranscriptionOwnsThePipelineUntilItsLastAwait() async throws {
    let assets = try Assets(meta: Data(smallGeometry.utf8), vocab: Data("[\"word\"]".utf8),
                            embeddingBytes: Data(repeating: 0, count: 8))
    let engine = TestEngine()
    let buffers = try PipelineBuffers(configuration: assets.configuration, lanes: 1, batch: 3)
    let voz = Voz(assets: assets, engine: engine, buffers: buffers)

    // A failed run must release the pipeline rather than wedge it.
    engine.failNext = true
    await #expect(throws: VozError.self) {
        try await voz.transcribe(samples: [Float](repeating: 0, count: 800))
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<4 {
            group.addTask {
                _ = try await voz.transcribe(samples: [Float](repeating: 0, count: 800))
            }
        }
        try await group.waitForAll()
    }
    #expect(engine.peak == 1, "two transcriptions must never share the buffers")
}
