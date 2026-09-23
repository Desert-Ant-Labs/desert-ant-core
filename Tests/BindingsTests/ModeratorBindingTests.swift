import Testing
import Foundation
import DesertAnt
import TestSupport
@_spi(ModeratorBindings) @testable import Moderator

/// Moderator's half of the cross-language binding: the image payload a host
/// encodes, the options beside it, and the result it decodes. Pinned here because
/// Kotlin and JS write these bytes by hand.
#if !os(WASI)
@Suite(.serialized, .modelBacked)
struct ModeratorBindingTests {
    /// `MODERATOR_MODEL_DIR` points at a local export until the pinned revision is published.
    private func moderator() -> Moderator {
        Moderator(directory: ProcessInfo.processInfo.environment["MODERATOR_MODEL_DIR"])
    }

    private func image(width: Int = 40, height: Int = 30, channels: Int = 3) -> FFIReader {
        var w = FFIWriter()
        w.u32(width)
        w.u32(height)
        w.u32(channels)
        let bytes = (0..<(width * height * channels)).map { UInt8(truncatingIfNeeded: $0 &* 37) }
        w.u32(bytes.count)
        w.raw(bytes)
        return FFIReader(w.bytes)
    }

    private func options(threshold: Double, policy: Int, quality: Int) -> FFIReader {
        var w = FFIWriter()
        w.f64(threshold)
        w.u32(policy)
        w.u32(quality)
        return FFIReader(w.bytes)
    }

    /// `f64 score`, `u32 isNSFW`, five region `f64`s, and nothing after.
    @Test func imagePayloadRoundTrip() async throws {
        let payload = try #require(await moderator().run(input: image(), options: FFIReader([])))
        var reader = FFIReader(payload)
        let score = reader.f64()
        let flagged = reader.u32()
        let regions = (0..<5).map { _ in reader.f64() }
        #expect(reader.isAtEnd)
        #expect(score == regions.max())
        #expect(flagged == (score >= 0.5 ? 1 : 0))
        #expect(regions.allSatisfy { (0...1).contains($0) })
    }

    /// Threshold and policy reach the core: 0 flags anything, and allowTopless
    /// leaves nipples out of the score.
    @Test func optionsAreDecoded() async throws {
        let payload = try #require(await moderator().run(
            input: image(), options: options(threshold: 0, policy: 1, quality: 0)))
        var reader = FFIReader(payload)
        let score = reader.f64()
        #expect(reader.u32() == 1)
        let regions = (0..<5).map { _ in reader.f64() }
        #expect(score == regions.dropFirst().max())
    }

    /// A buffer whose size does not match its header is rejected, not read past.
    @Test func malformedImageIsRejected() async {
        var w = FFIWriter()
        w.u32(1000)
        w.u32(1000)
        w.u32(4)
        w.u32(3)
        w.raw([1, 2, 3])
        #expect(await moderator().run(input: FFIReader(w.bytes), options: FFIReader([])) == nil)
        #expect(await moderator().run(input: FFIReader([0, 0]), options: FFIReader([])) == nil)
    }

    @Test func bindingOwnsTheCatalogId() {
        #expect(ModeratorBinding.id == "moderator")
    }
}
#endif
