import XCTest
import Foundation
import DesertAnt
import TestSupport
@_spi(ClearBindings) @testable import Clear
import Emo
import Redact
import Shapes

/// The model-specific half of the cross-language binding: the payload schemas a
/// host encodes and decodes. Each model owns its own adapter, so no model can
/// reach another's.
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

    /// The audio payload contract: audio in through the generic `run(input:options:)`
    /// entry, samples out, decoded with the same reader a host uses. There is no
    /// audio-specific symbol anywhere - the modality is entirely this payload.
    func testAudioPayloadRoundTrip() async throws {
        try requireModelBacked()
        let clear = try await enhancer()
        var input = FFIWriter()
        input.f32Array(noisyTone())
        input.f64(48_000)
        var options = FFIWriter()
        options.f64(1.0)        // strength
        options.f64(.nan)       // integratedLUFS: mastering bypassed
        options.f64(-1.5)       // true-peak ceiling
        options.f64(9)          // max loudness gain
        guard let payload = await clear.run(input: FFIReader(input.bytes),
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

    func testEachBindingOwnsOnlyItsCatalogId() {
        XCTAssertEqual(EmoBinding.id, "emo")
        XCTAssertEqual(RedactBinding.id, "redact")
        XCTAssertEqual(ClearBinding.id, "clear")
        XCTAssertEqual(ShapesBinding.id, "shapes")
    }
#endif
}
