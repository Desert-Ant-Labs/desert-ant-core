import Testing
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
#if !os(WASI)
@Suite(.modelBacked)
struct ClearBindingTests {
    /// The enhancer, or nil where no runtime can load the artifact. Swift
    /// Testing has no runtime skip, so a host without a runtime returns early
    /// from the test rather than failing (the XCTest version threw `XCTSkip`).
    private func enhancer() async throws -> Clear? {
        let files = try await ModelFixture.files(ClearModel.self)
        return try? Clear(modelPath: files.path(ClearModel.artifact))
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
    @Test func audioPayloadRoundTrip() async throws {
        guard let clear = try await enhancer() else { return }  // no runtime on this host
        var input = FFIWriter()
        input.f32Array(noisyTone())
        input.f64(48_000)
        var options = FFIWriter()
        options.f64(1.0)        // strength
        options.f64(.nan)       // integratedLUFS: mastering bypassed
        options.f64(-1.5)       // true-peak ceiling
        options.f64(9)          // max loudness gain
        let payload = try #require(
            await clear.run(input: FFIReader(input.bytes), options: FFIReader(options.bytes)),
            "the audio binding returned no payload")
        var reader = FFIReader(payload)
        let samples = reader.f32Array()
        #expect(!samples.isEmpty)
        #expect(reader.f64() == 48_000)            // sample rate
        #expect(reader.f64() > 0)                  // duration
        #expect(reader.f64() > 0)                  // processing time
        #expect(reader.f64().isNaN)                // measured LUFS: none, mastering off
    }

    @Test func eachBindingOwnsOnlyItsCatalogId() {
        #expect(EmoBinding.id == "emo")
        #expect(RedactBinding.id == "redact")
        #expect(ClearBinding.id == "clear")
        #expect(ShapesBinding.id == "shapes")
    }
}
#endif
