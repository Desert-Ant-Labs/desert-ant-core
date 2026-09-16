import Testing
import Foundation
import DesertAnt
import TestSupport
@_spi(AlignBindings) @testable import Align

/// Align's half of the cross-language binding: the word-timing payload a host
/// encodes and the corrected one it decodes. Worth pinning on its own because
/// align is the first model whose input carries both audio and a structure over
/// it, which is a payload schema rather than a second entry point.
#if !os(WASI)
// Serialized like every other model-backed suite, see ShapesBindingTests for the
// LiteRT global-registry race that concurrent session creation trips.
@Suite(.serialized, .modelBacked)
struct AlignBindingTests {
    /// A refiner over the cached model, reached through the binding only.
    private func refiner() async throws -> Align {
        let files = try await ModelFixture.files(AlignModel.self)
        return Align(assets: try await .align(files: files, computeUnits: .cpuOnly, revision: nil))
    }

    /// 3 s of tone at 16 kHz.
    private func tone(sampleRate: Int) -> [Float] {
        (0..<sampleRate * 3).map { 0.3 * Float(sin(2 * .pi * 200 * Double($0) / Double(sampleRate))) }
    }

    /// The word-timing payload contract: audio and proposed times in through the
    /// generic `run(input:options:)` entry, corrected times out, decoded with the
    /// same reader a host uses.
    @Test func wordPayloadRoundTrip() async throws {
        let sampleRate = 16_000
        var input = FFIWriter()
        input.f32Array(tone(sampleRate: sampleRate))
        input.f64(Double(sampleRate))
        input.u32(2)
        input.string("hola")
        input.f64(0.40)
        input.f64(0.71)
        input.string("mundo")
        input.f64(0.80)
        input.f64(1.30)
        var options = FFIWriter()
        options.string("es")
        let payload = try #require(
            await refiner().run(input: FFIReader(input.bytes), options: FFIReader(options.bytes)),
            "the word-timing binding returned no payload")
        var reader = FFIReader(payload)
        #expect(reader.u32() == 2)
        for _ in 0..<2 {
            let start = reader.f64(), end = reader.f64(), refined = reader.u32()
            #expect(start < end)
            #expect(refined == 0 || refined == 1, "refined is a 0/1 flag")
        }
        #expect(reader.isAtEnd, "the word payload is fully consumed")
    }

    /// A payload with no audio is a failed run, not a crash: the guard answers
    /// before anything loads, so a host that lies about its counts gets a NULL
    /// buffer instead of an allocation the size of its count field.
    @Test func malformedInputPayloadIsRejected() async throws {
        let align = Align(directory: nil, cacheRoot: nil)
        #expect(await align.run(input: FFIReader([]), options: FFIReader([])) == nil)
        var w = FFIWriter()
        w.f32Array([0.1, 0.2])
        w.f64(16_000)
        w.u32(1 << 30)
        #expect(await align.run(input: FFIReader(w.bytes), options: FFIReader([])) == nil)
    }

    @Test func bindingOwnsTheCatalogId() {
        #expect(AlignBinding.id == "align")
    }
}
#endif
