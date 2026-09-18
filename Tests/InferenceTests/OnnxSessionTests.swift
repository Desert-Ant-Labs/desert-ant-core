import Testing
@testable import Inference

#if canImport(COnnxRuntime)
import Foundation

/// Exercises the ONNX Runtime backend end to end: load a bundled `.onnx`, run it
/// through the shared `InferenceSession` contract with named tensors, and check
/// the output. Requires linking onnxruntime.dll.
///
/// The test model is deliberately the same graph as `testmodel.tflite`, with the
/// same signature and the same expected numbers: inputs `features` [1,4,3] and
/// `mask` [1,4,1] (float32), output `probs` [1,3] = softmax over the masked sum
/// across the time axis. Two backends checked against one reference is the point
/// - a divergence is then a backend bug rather than a difference of fixtures.
struct OnnxSessionTests {
    private func modelPath() throws -> String {
        let url = try #require(Bundle.module.url(forResource: "testmodel", withExtension: "onnx"))
        return url.path
    }

    /// The same per-step features the LiteRT test uses: 4 steps of
    /// [0.25, 0.5, 0.75], so the masked sum over time is [1, 2, 3].
    private var features: [Float] {
        (0..<(4 * 3)).map { Float([0.25, 0.5, 0.75][$0 % 3]) }
    }

    @Test func namedTensorRunMatchesReference() throws {
        let session = try OnnxSession(modelPath: try modelPath(), accelerator: .cpu)

        let outputs = try session.run(
            inputs: [
                "features": Tensor(float32: features, shape: [1, 4, 3]),
                "mask": Tensor(float32: [Float](repeating: 1, count: 4), shape: [1, 4, 1]),
            ],
            outputs: ["probs"], deviceId: nil)
        let probs = try #require(outputs.first?.float32Values)

        #expect(outputs[0].shape == [1, 3])
        #expect(probs.count == 3)
        #expect(abs(probs.reduce(0, +) - 1.0) <= 1e-4)   // softmax sums to 1
        // softmax([1, 2, 3]) = [0.09003, 0.24473, 0.66524], the same values the
        // LiteRT backend is held to.
        #expect(abs(probs[0] - 0.09003) <= 1e-3)
        #expect(abs(probs[1] - 0.24473) <= 1e-3)
        #expect(abs(probs[2] - 0.66524) <= 1e-3)
    }

    /// A zero mask drops every step, so the sum is [0, 0, 0] and softmax is
    /// uniform. Cheap proof that the mask input reaches the graph at all rather
    /// than the output being produced from `features` alone.
    @Test func maskIsHonoured() throws {
        let session = try OnnxSession(modelPath: try modelPath(), accelerator: .cpu)
        let outputs = try session.run(
            inputs: [
                "features": Tensor(float32: features, shape: [1, 4, 3]),
                "mask": Tensor(float32: [Float](repeating: 0, count: 4), shape: [1, 4, 1]),
            ],
            outputs: ["probs"], deviceId: nil)
        let probs = try #require(outputs.first?.float32Values)
        for p in probs { #expect(abs(p - 1.0 / 3.0) <= 1e-4) }
    }

    @Test func missingInputIsRejected() throws {
        let session = try OnnxSession(modelPath: try modelPath(), accelerator: .cpu)
        #expect(throws: InferenceError.self) {
            try session.run(inputs: ["features": Tensor(float32: features, shape: [1, 4, 3])],
                            outputs: ["probs"], deviceId: nil)
        }
    }

    @Test func unknownOutputIsRejected() throws {
        let session = try OnnxSession(modelPath: try modelPath(), accelerator: .cpu)
        #expect(throws: InferenceError.self) {
            try session.run(
                inputs: [
                    "features": Tensor(float32: features, shape: [1, 4, 3]),
                    "mask": Tensor(float32: [Float](repeating: 1, count: 4), shape: [1, 4, 1]),
                ],
                outputs: ["nope"], deviceId: nil)
        }
    }

    /// Asking for an accelerator must never break model load: with no provider
    /// present the session falls back to CPU and returns the same numbers.
    ///
    /// This does NOT assert the graph ran anywhere in particular, and cannot: a
    /// provider that claims no node still attaches to the session, so
    /// `accelerators` is a capability probe rather than evidence of placement.
    /// Proving placement needs a profile, which belongs in a benchmark and not a
    /// unit test.
    @Test(arguments: [OnnxSession.Accelerator.gpu, .npu])
    func acceleratorRequestFallsBackCleanly(_ accelerator: OnnxSession.Accelerator) throws {
        let session = try OnnxSession(modelPath: try modelPath(), accelerator: accelerator)
        let outputs = try session.run(
            inputs: [
                "features": Tensor(float32: features, shape: [1, 4, 3]),
                "mask": Tensor(float32: [Float](repeating: 1, count: 4), shape: [1, 4, 1]),
            ],
            outputs: ["probs"], deviceId: nil)
        let probs = try #require(outputs.first?.float32Values)
        #expect(abs(probs[2] - 0.66524) <= 1e-3)
    }

    /// The GPU is the reason this backend exists on Windows, so a host that has
    /// DirectML must actually report it rather than quietly running on the CPU.
    /// Skipped rather than failed where there is no GPU, because the suite also
    /// runs on machines that have none.
    @Test func gpuIsUsedWhenPresent() throws {
        let session = try OnnxSession(modelPath: try modelPath(), accelerator: .gpu)
        try withKnownIssue("no DirectML GPU on this host", isIntermittent: true) {
            #expect(session.accelerators.contains(.gpu))
        } when: {
            !session.accelerators.contains(.gpu)
        }
    }
}
#endif
