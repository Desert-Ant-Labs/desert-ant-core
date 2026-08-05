import XCTest
import Foundation
import DesertAnt
import TestSupport
@_spi(ClearBindings) import Clear
@testable import Bindings

/// The model-specific half of the cross-language binding: the payload schemas a
/// host encodes and decodes. The conformances live in `Bindings` (a model module
/// never references `FFIBuffer`), so their tests live here too.
final class ClearBindingTests: XCTestCase {
#if !os(WASI)
    private func requireModelBacked() throws {
        try XCTSkipUnless(runsModelBackedTests, "model-backed tests do not run on iOS or Android")
    }

    private func enhancer() async throws -> Clear {
        let files = try await ModelFixture.files(ClearModel.self)
        do { return try Clear(modelPath: files.path(ClearModel.artifact)) }
        catch { throw XCTSkip("no runtime for \(ClearModel.artifact) on this host: \(error)") }
    }

    /// 2.5 s of tone plus deterministic noise at 48 kHz.
    private func noisyTone() -> [Float] {
        var x = (0..<120_000).map { 0.3 * Float(sin(2 * .pi * 220 * Double($0) / 48_000)) }
        var seed: UInt64 = 1
        for i in 0..<x.count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            x[i] += 0.15 * (Float(seed >> 40) / Float(1 << 24) - 0.5)
        }
        return x
    }

    /// The audio payload contract (`dal_run_audio`): options in and samples out,
    /// decoded with the same reader a host uses.
    func testAudioPayloadRoundTrip() async throws {
        try requireModelBacked()
        let clear = try await enhancer()
        var options = FFIWriter()
        options.f64(1.0)        // strength
        options.f64(.nan)       // integratedLUFS: mastering bypassed
        options.f64(-1.5)       // true-peak ceiling
        options.f64(9)          // max loudness gain
        guard let payload = await clear.run(audio: noisyTone(), sampleRate: 48_000,
                                            options: FFIReader(options.bytes)) else {
            return XCTFail("the audio binding returned no payload")
        }
        var reader = FFIReader(payload)
        let samples = reader.f32Array()
        XCTAssertFalse(samples.isEmpty)
        XCTAssertEqual(reader.f64(), 48_000)            // sample rate
        XCTAssertGreaterThan(reader.f64(), 0)           // duration
        XCTAssertGreaterThan(reader.f64(), 0)           // processing time
        XCTAssertTrue(reader.f64().isNaN)               // measured LUFS: none, mastering off
    }

    /// Every model in the registry is reachable by its catalog id, which is how
    /// a host asks for one over the C ABI.
    func testRegistryResolvesEveryModelId() {
        for id in ["emo", "redact", "clear"] {
            XCTAssertNotNil(binding(for: id), "no binding registered for '\(id)'")
        }
        XCTAssertNil(binding(for: "not-a-model"))
    }
#endif
}
