import XCTest
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
final class LiteRTSessionTests: XCTestCase {
    private func modelPath() throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "testmodel", withExtension: "tflite"))
        return url.path
    }

    func testNamedTensorRunMatchesReference() throws {
        let session = try LiteRTSession(modelPath: try modelPath())

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
            outputs: ["probs"])
        let probs = try XCTUnwrap(outputs.first?.float32Values)

        XCTAssertEqual(outputs[0].shape, [1, 3])
        XCTAssertEqual(probs.count, 3)
        XCTAssertEqual(probs.reduce(0, +), 1.0, accuracy: 1e-4)   // softmax sums to 1
        // softmax([1, 2, 3]) = [0.09003, 0.24473, 0.66524]
        XCTAssertEqual(probs[0], 0.09003, accuracy: 1e-3)
        XCTAssertEqual(probs[1], 0.24473, accuracy: 1e-3)
        XCTAssertEqual(probs[2], 0.66524, accuracy: 1e-3)
    }

    func testInMemoryModelBytes() throws {
        let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: try modelPath())))
        let session = try LiteRTSession(modelPath: "", modelBytes: bytes)
        let outputs = try session.run(
            inputs: [
                "features": Tensor(float32: [Float](repeating: 0, count: 12), shape: [1, 4, 3]),
                "mask": Tensor(float32: [Float](repeating: 1, count: 4), shape: [1, 4, 1]),
            ],
            outputs: ["probs"])
        // All-zero features -> softmax([0,0,0]) = [1/3, 1/3, 1/3].
        let probs = try XCTUnwrap(outputs.first?.float32Values)
        for p in probs { XCTAssertEqual(p, 1.0 / 3.0, accuracy: 1e-4) }
    }

    func testMissingInputThrows() throws {
        let session = try LiteRTSession(modelPath: try modelPath())
        XCTAssertThrowsError(try session.run(
            inputs: ["features": Tensor(float32: [Float](repeating: 0, count: 12), shape: [1, 4, 3])],
            outputs: ["probs"]))
    }
}
#endif
