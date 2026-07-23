import Testing
@testable import Inference

#if DAL_LITERT
import Foundation

/// Exercises the LiteRT backend end to end: load a bundled `.tflite`, run it
/// through the shared `InferenceSession` contract with named tensors, and check
/// the output. Only compiled when the LiteRT backend is selected
/// (DAL_INFERENCE_LITERT), and requires linking libLiteRt.so.
///
/// The test model mirrors a shapes-style signature: inputs `features` [1,4,3]
/// and `mask` [1,4,1] (float32), output `probs` [1,3] = softmax over the
/// masked sum across the time axis. Feeding per-step features that sum to
/// [1, 2, 3] makes `probs` == softmax([1, 2, 3]).
struct LiteRTSessionTests {
    private func modelPath() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "testmodel", withExtension: "tflite"))
        return url.path
    }

    @Test func namedTensorRunMatchesReference() throws {
        // Pin CPU for an exact numeric reference: the default (.auto) may run on
        // a GPU accelerator when one is bundled, whose kernels differ by ~1e-3.
        let session = try LiteRTSession(modelPath: try modelPath(), accelerator: .cpu)

        // 4 time steps, each [0.25, 0.5, 0.75]; masked sum over time = [1, 2, 3].
        let features = [Float](repeating: 0, count: 4 * 3).enumerated().map { i, _ in
            Float([0.25, 0.5, 0.75][i % 3])
        }
        let mask = [Float](repeating: 1, count: 4)

        let outputs = try session.run(
            inputs: [
                "features": Tensor(float32: features, shape: [1, 4, 3]),
                "mask": Tensor(float32: mask, shape: [1, 4, 1]),
            ],
            outputs: ["probs"], deviceId: nil)
        let probs = try #require(outputs.first?.float32Values)

        #expect(outputs[0].shape == [1, 3])
        #expect(probs.count == 3)
        #expect(abs(probs.reduce(0, +) - 1.0) <= 1e-4)   // softmax sums to 1
        // softmax([1, 2, 3]) = [0.09003, 0.24473, 0.66524]
        #expect(abs(probs[0] - 0.09003) <= 1e-3)
        #expect(abs(probs[1] - 0.24473) <= 1e-3)
        #expect(abs(probs[2] - 0.66524) <= 1e-3)
    }

    /// The default accelerator is `.auto` (prefer GPU when its accelerator
    /// library is bundled, else CPU). It must always load and run and produce a
    /// valid softmax, whichever backend it lands on (GPU kernels differ from CPU
    /// by ~1e-3, so assert loosely).
    @Test func autoAcceleratorRunsAndFallsBack() throws {
        let session = try LiteRTSession(modelPath: try modelPath())   // .auto
        let features = [Float](repeating: 0, count: 4 * 3).enumerated().map { i, _ in
            Float([0.25, 0.5, 0.75][i % 3])
        }
        let outputs = try session.run(
            inputs: [
                "features": Tensor(float32: features, shape: [1, 4, 3]),
                "mask": Tensor(float32: [Float](repeating: 1, count: 4), shape: [1, 4, 1]),
            ],
            outputs: ["probs"], deviceId: nil)
        let probs = try #require(outputs.first?.float32Values)
        #expect(outputs[0].shape == [1, 3])
        #expect(abs(probs.reduce(0, +) - 1.0) <= 1e-2)
        #expect(abs(probs[2] - 0.66524) <= 1e-2)   // largest class, backend-agnostic
    }

    @Test func inMemoryModelBytes() throws {
        let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: try modelPath())))
        let session = try LiteRTSession(modelPath: "", modelBytes: bytes)
        let outputs = try session.run(
            inputs: [
                "features": Tensor(float32: [Float](repeating: 0, count: 12), shape: [1, 4, 3]),
                "mask": Tensor(float32: [Float](repeating: 1, count: 4), shape: [1, 4, 1]),
            ],
            outputs: ["probs"], deviceId: nil)
        // All-zero features -> softmax([0,0,0]) = [1/3, 1/3, 1/3].
        let probs = try #require(outputs.first?.float32Values)
        for p in probs { #expect(abs(p - 1.0 / 3.0) <= 1e-4) }
    }

    /// The session must own its copy of the model bytes: LiteRT keeps a
    /// zero-copy reference to the buffer, so a caller that frees or reuses the
    /// source bytes right after creation (e.g. the Android bindings pass a
    /// transient byte[]) must not corrupt the model. This smoke-tests that the
    /// bytes path survives the source being overwritten and dropped. (The tiny
    /// test model is fully deserialized at create, so the dangling-weights crash
    /// only surfaces with a large real model, e.g. redact's Android integration
    /// test; this still guards the ownership contract on the bytes path.)
    @Test func inMemoryModelBytesSurvivesSourceMutation() throws {
        let session: LiteRTSession
        do {
            var bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: try modelPath())))
            session = try LiteRTSession(modelPath: "", modelBytes: bytes)
            // Overwrite the source the model was created from; the shim's own
            // copy must be unaffected.
            for i in bytes.indices { bytes[i] = 0 }
            _ = bytes.count
        }
        // Force some churn so a freed buffer would likely be reused/unmapped.
        var scratch = [[UInt8]]()
        for _ in 0..<8 { scratch.append([UInt8](repeating: 0xAB, count: 1 << 20)) }
        _ = scratch.count
        let outputs = try session.run(
            inputs: [
                "features": Tensor(float32: [Float](repeating: 0, count: 12), shape: [1, 4, 3]),
                "mask": Tensor(float32: [Float](repeating: 1, count: 4), shape: [1, 4, 1]),
            ],
            outputs: ["probs"], deviceId: nil)
        let probs = try #require(outputs.first?.float32Values)
        for p in probs { #expect(abs(p - 1.0 / 3.0) <= 1e-4) }
    }

    @Test func missingInputThrows() throws {
        let session = try LiteRTSession(modelPath: try modelPath())
        #expect(throws: (any Error).self) {
            try session.run(
                inputs: ["features": Tensor(float32: [Float](repeating: 0, count: 12), shape: [1, 4, 3])],
                outputs: ["probs"], deviceId: nil)
        }
    }
}
#endif
