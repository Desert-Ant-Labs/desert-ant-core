import Testing
import Foundation
import DesertAnt
import TestSupport
@_spi(UhmBindings) @testable import Uhm

#if !os(WASI)
@Suite(.serialized, .modelBacked)
struct UhmBindingTests {
    private func detector() async throws -> Uhm? {
        let files = try await ModelFixture.files(UhmModel.self)
        return try? Uhm(modelPath: files.path(UhmModel.artifact(for: .current)))
    }

    private func silence() -> [Float] { [Float](repeating: 0.001, count: 32_000) }

    @Test func audioPayloadRoundTrip() async throws {
        guard let uhm = try await detector() else { return }
        var input = FFIWriter()
        input.f32Array(silence())
        input.f64(16_000)
        let payload = try #require(
            await uhm.run(input: FFIReader(input.bytes), options: FFIReader([])),
            "the audio binding returned no payload")
        var reader = FFIReader(payload)
        #expect(abs(reader.f64() - 2.0) < 0.05)
        let fillers = reader.u32()
        for _ in 0..<fillers { _ = reader.f64(); _ = reader.f64(); _ = reader.f64(); _ = reader.string() }
        #expect(reader.isAtEnd, "no words in, no words out")
    }

    @Test func wordsAreReconciledWhenSent() async throws {
        guard let uhm = try await detector() else { return }
        var input = FFIWriter()
        input.f32Array(silence())
        input.f64(16_000)
        input.u32(2)
        input.f64(0.1); input.f64(0.5); input.string("hi")
        input.f64(1.2); input.f64(1.2); input.string("void")
        let payload = try #require(
            await uhm.run(input: FFIReader(input.bytes), options: FFIReader([])))
        var reader = FFIReader(payload)
        _ = reader.f64()
        let fillers = reader.u32()
        for _ in 0..<fillers { _ = reader.f64(); _ = reader.f64(); _ = reader.f64(); _ = reader.string() }
        #expect(reader.u32() == 1, "zero-duration words are filtered like reconcileWords does")
        #expect(reader.f64() == 0.1)
        #expect(reader.f64() == 0.5)
        #expect(reader.string() == "hi")
        #expect(reader.isAtEnd)
    }

    @Test func aWordCountLargerThanThePayloadIsRejected() async throws {
        guard let uhm = try await detector() else { return }
        var input = FFIWriter()
        input.f32Array(silence())
        input.f64(16_000)
        input.u32(1_000_000)
        #expect(await uhm.run(input: FFIReader(input.bytes), options: FFIReader([])) == nil)
    }

    @Test func bindingOwnsItsCatalogId() {
        #expect(UhmBinding.id == "uhm")
    }
}
#endif
