import Testing
import Foundation
import DesertAnt
import TestSupport
@_spi(SchemerBindings) @testable import Schemer

/// Schemer's half of the cross-language binding: the text-and-schema payload a
/// host encodes, the anchor beside it, and the typed values it decodes. Pinned
/// here because Kotlin and JS write these bytes by hand.
#if !os(WASI)
@Suite(.serialized, .modelBacked)
struct SchemerBindingTests {
    /// `SCHEMER_MODEL_DIR` points at a local export until the pinned revision is published.
    private static let schemer = Schemer(directory: ProcessInfo.processInfo.environment["SCHEMER_MODEL_DIR"])

    private func anchor(_ date: String) -> FFIReader {
        var w = FFIWriter()
        w.string("today=\(date)")
        return FFIReader(w.bytes)
    }

    /// Every kind crosses in schema order, and the anchor reaches relative dates.
    @Test func payloadRoundTrip() async throws {
        var w = FFIWriter()
        w.string("Coffee at Blue Bottle, $18.50, reimbursable. Tomorrow at 9:30 with Dana and Priya.")
        w.u32(6)
        w.string("merchant"); w.u32(0); w.string("the shop or vendor"); w.u32(2)
        w.string("amount"); w.u32(1); w.string("total paid"); w.u32(2)
        w.u32(0); w.f64(0); w.u32(0); w.f64(0); w.string("currency")
        w.string("reimbursable"); w.u32(2); w.string(""); w.u32(2)
        w.string("category"); w.u32(4); w.string(""); w.u32(2)
        w.u32(3); w.string("food"); w.string("travel"); w.string("office")
        w.string("when"); w.u32(3); w.string(""); w.u32(2)
        w.string("attendees"); w.u32(5); w.string("people present"); w.u32(2)

        let payload = try #require(await Self.schemer.run(input: FFIReader(w.bytes),
                                                            options: anchor("2026-03-10")))
        var r = FFIReader(payload)
        #expect(r.u32() == 6)
        #expect(r.u32() == 1); #expect(r.string() == "Blue Bottle")
        #expect(r.u32() == 2); #expect(r.f64() == 18.5)
        #expect(r.u32() == 3); #expect(r.u32() == 1)
        #expect(r.u32() == 5); #expect(r.string() == "food")
        #expect(r.u32() == 4); #expect(r.string() == "2026-03-11T09:30")
        #expect(r.u32() == 6); #expect(r.strings() == ["Dana", "Priya"])
        #expect(r.u32() == 0)                                  // not truncated
        #expect(r.isAtEnd)
    }

    /// The binding and the Swift API agree on the same schema, including a
    /// nullable nobody stated.
    @Test func bindingMatchesTheSwiftAPI() async throws {
        let text = "Thanks for the update, see you next week."
        var w = FFIWriter()
        w.string(text)
        w.u32(2)
        w.string("total"); w.u32(1); w.string("order total"); w.u32(2)
        w.u32(0); w.f64(0); w.u32(0); w.f64(0); w.string("")
        w.string("ship_date"); w.u32(3); w.string("shipping date"); w.u32(1)
        let payload = try #require(await Self.schemer.run(input: FFIReader(w.bytes),
                                                            options: anchor("2026-03-10")))
        let direct = try await Self.schemer.extract(
            from: text,
            schema: [.number("total", describe: "order total"),
                     .datetime("ship_date", describe: "shipping date", nullable: true)],
            now: Schemer.date(fromAnchor: "today=2026-03-10")!)
        var r = FFIReader(payload)
        #expect(r.u32() == 2)
        for (_, value) in direct.values {
            switch value {
            case .null: #expect(r.u32() == 0)
            case .number(let d): #expect(r.u32() == 2); #expect(r.f64() == d)
            case .datetime(let s): #expect(r.u32() == 4); #expect(r.string() == s)
            default: Issue.record("unexpected \(value)")
            }
        }
        #expect(r.u32() == (direct.truncated ? 1 : 0))
        #expect(r.isAtEnd)
    }

    /// An empty options payload means the device clock, not an error.
    @Test func emptyOptionsUseTheClock() async throws {
        var w = FFIWriter()
        w.string("Lunch at Noma")
        w.u32(1)
        w.string("place"); w.u32(0); w.string(""); w.u32(2)
        let payload = try #require(await Self.schemer.run(input: FFIReader(w.bytes), options: FFIReader([])))
        var r = FFIReader(payload)
        #expect(r.u32() == 1)
    }

    /// A payload no conforming host writes is refused, not guessed at.
    @Test func malformedPayloadIsRejected() async {
        var w = FFIWriter()
        w.string("x")
        w.u32(1)
        w.string("f"); w.u32(9); w.string(""); w.u32(2)     // type 9 does not exist
        #expect(await Self.schemer.run(input: FFIReader(w.bytes), options: FFIReader([])) == nil)

        // A schema the runtime cannot honor fails the run rather than returning
        // a half-filled result.
        var dup = FFIWriter()
        dup.string("x")
        dup.u32(2)
        dup.string("a"); dup.u32(0); dup.string(""); dup.u32(2)
        dup.string("a"); dup.u32(2); dup.string(""); dup.u32(2)
        #expect(await Self.schemer.run(input: FFIReader(dup.bytes), options: FFIReader([])) == nil)

        // Counts the payload cannot hold are refused before anything is
        // reserved or looped over for them.
        var huge = FFIWriter()
        huge.string("x")
        huge.u32(0xFFFF_FFFF)
        #expect(await Self.schemer.run(input: FFIReader(huge.bytes), options: FFIReader([])) == nil)
        var labels = FFIWriter()
        labels.string("x")
        labels.u32(1)
        labels.string("k"); labels.u32(4); labels.string(""); labels.u32(2); labels.u32(0xFFFF_FFFF)
        #expect(await Self.schemer.run(input: FFIReader(labels.bytes), options: FFIReader([])) == nil)
    }

    @Test func bindingOwnsTheCatalogId() {
        #expect(SchemerBinding.id == "schemer")
    }
}
#endif
