import Testing
import Foundation
import DesertAnt
import TestSupport
@_spi(ToxicBindings) @testable import Toxic

/// Toxic's half of the cross-language binding: the text payload a host encodes,
/// the thresholds beside it, and the analysis it decodes. Pinned here because
/// Kotlin and JS write these bytes by hand.
#if !os(WASI)
@Suite(.serialized, .modelBacked)
struct ToxicBindingTests {
    /// `TOXIC_MODEL_DIR` points at a local export until the pinned revision is published.
    private func toxic() -> Toxic {
        Toxic(directory: ProcessInfo.processInfo.environment["TOXIC_MODEL_DIR"])
    }

    private func text(_ s: String) -> FFIReader {
        var w = FFIWriter()
        w.string(s)
        return FFIReader(w.bytes)
    }

    private func options(_ thresholds: [(String, Double)]) -> FFIReader {
        var w = FFIWriter()
        w.u32(thresholds.count)
        for (label, threshold) in thresholds {
            w.string(label)
            w.f64(threshold)
        }
        return FFIReader(w.bytes)
    }

    /// `u32 count`, then per head `string label`, `f64 score`, `f64 threshold`, `u32 flagged`, and nothing after.
    @Test func textPayloadRoundTrip() async throws {
        let payload = try #require(await toxic().run(input: text("Go back to where you came from, nobody wants you here."), options: FFIReader([])))
        var reader = FFIReader(payload)
        let count = reader.u32()
        #expect(count == Label.allCases.count)
        var flagged: [String] = []
        for label in Label.allCases {
            #expect(reader.string() == label.rawValue)
            let score = reader.f64()
            let threshold = reader.f64()
            let flag = reader.u32()
            #expect((0...1).contains(score) && (0...1).contains(threshold) && (flag == 0 || flag == 1))
            #expect(flag == (score >= threshold ? 1 : 0))
            if flag == 1 { flagged.append(label.rawValue) }
        }
        #expect(reader.isAtEnd)
        #expect(flagged.contains("HATEFUL"))
    }

    /// A threshold reaches the core: 0 flags the head named and leaves the others at their defaults.
    @Test func thresholdsAreDecoded() async throws {
        let payload = try #require(await toxic().run(input: text("hello"), options: options([("AGE", 0), ("NOPE", 0.1)])))
        var reader = FFIReader(payload)
        _ = reader.u32()
        var seen: [String: (Double, Int)] = [:]
        for _ in Label.allCases {
            let label = reader.string()
            _ = reader.f64()
            seen[label] = (reader.f64(), reader.u32())
        }
        #expect(seen["AGE"]?.0 == 0 && seen["AGE"]?.1 == 1)
        #expect(seen["HATEFUL"]?.0 != 0)
    }

    @Test func bindingIsRegisteredUnderTheCatalogID() {
        #expect(ToxicBinding.id == "toxic")
    }
}
#endif
