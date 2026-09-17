import Foundation
import Testing
@testable import Voz

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
    var fusedFrontend = false
    var staged = 0
    var melCalls = 0
    var active = 0
    var peak = 0
    var failNext = false

    func stage(lanes: Int) { staged = lanes }
    func runMel(rows: Buffer, melMask: Buffer, mel: Buffer,
                isolation: isolated (any Actor)?) async throws { melCalls += 1 }
    func runEncoder(mel: Buffer, keyBias: Buffer, padMask: Buffer, encOut: Buffer,
                    isolation: isolated (any Actor)?) async throws {
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(nanoseconds: 1_000_000)
        if failNext {
            failNext = false
            throw VozError.invalidModel("test failure")
        }
        for i in 0..<encOut.count { encOut.ptr[i] = Element(i + 1) }
    }
    func runDecodeStep(embed: Buffer, hIn: Buffer, cIn: Buffer, encStep: Buffer,
                       logits: Buffer, tok: inout [Int32], dur: inout [Int32],
                       hOut: Buffer, cOut: Buffer,
                       isolation: isolated (any Actor)?) async throws {
        tok = [1, 1]
        dur = [0, 0]
    }
}

@Test func tensorBatchCopiesOnlyLiveLanes() async throws {
    let c = try JSONDecoder().decode(Configuration.self, from: Data(smallGeometry.utf8))
    let buffers = try PipelineBuffers(configuration: c, lanes: 1, batch: 3)
    let engine = TestEngine()
    let out = try Buffer([12])
    out.ptr.update(repeating: -1, count: out.count)
    try await engine.encode(count: 2, buffers: buffers, into: out.ptr, stride: 4, isolation: nil)
    #expect(engine.staged == 2)
    #expect(engine.melCalls == 1)
    #expect(Array(UnsafeBufferPointer(start: out.ptr, count: 12))
            == [1, 2, 3, 4, 5, 6, 7, 8, -1, -1, -1, -1])
    engine.fusedFrontend = true
    try await engine.encode(count: 1, buffers: buffers, into: out.ptr, stride: 4, isolation: nil)
    #expect(engine.melCalls == 1)
}

@Test func transcriptionsOwnBuffersUntilTheirLastAwait() async throws {
    let assets = try Assets(meta: Data(smallGeometry.utf8), vocab: Data("[\"word\"]".utf8),
                            embeddingBytes: Data(repeating: 0, count: 8))
    let engine = TestEngine()
    let buffers = try PipelineBuffers(configuration: assets.configuration, lanes: 1, batch: 3)
    let voz = Voz(assets: assets, engine: engine, buffers: buffers)
    engine.failNext = true
    await #expect(throws: VozError.self) {
        try await voz.transcribe(samples: [Float](repeating: 0, count: 800))
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<4 {
            group.addTask { _ = try await voz.transcribe(samples: [Float](repeating: 0, count: 800)) }
        }
        try await group.waitForAll()
    }
    #expect(engine.peak == 1)
}

#if canImport(CoreML)
import CoreML

@Test(arguments: [1, 2])
func nativeProjectionCopyHonorsPadding(frameStride: Int) throws {
    let channels = 3, frames = 5, channelStride = 16
    let storage = UnsafeMutablePointer<Element>.allocate(capacity: channels * channelStride)
    storage.initialize(repeating: -1, count: channels * channelStride)
    defer { storage.deallocate() }
    for c in 0..<channels {
        for f in 0..<frames { storage[c * channelStride + f * frameStride] = Element(c * frames + f) }
    }
    let array = try MLMultiArray(dataPointer: storage, shape: [1, 3, 1, 5], dataType: .float16,
                                 strides: [48, 16, 16, NSNumber(value: frameStride)])
    let out = try Buffer([1, channels, 1, frames])
    try CoreMLEngine.copyProjection(array, to: out.ptr, channels: channels, frames: frames)
    #expect(Array(UnsafeBufferPointer(start: out.ptr, count: out.count)) == (0..<15).map(Element.init))
}
#endif
