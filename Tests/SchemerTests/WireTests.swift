// Cross-language wire agreement.
//
// A round-trip inside one language cannot catch a shared misunderstanding of
// the format: both sides can be wrong the same way. `Resources/schemer_wire.*`
// are the bytes packages/schemer-node's encoder writes (its suite asserts it
// still writes exactly these), and this reads them back into the schema they
// mean. Regenerate after a deliberate format change with:
//
//     node packages/schemer-node/test/wire.mjs

import FFIBuffer
import Foundation
import Testing
@_spi(SchemerBindings) @testable import Schemer

#if !os(WASI)  // bundle resources are not readable under the wasm test harness
private func wire(_ ext: String) throws -> [UInt8] {
    let url = try #require(Bundle.module.url(forResource: "schemer_wire", withExtension: ext))
    return [UInt8](try Data(contentsOf: url))
}

@Test func swiftReadsTheJavaScriptInputPayload() throws {
    var r = FFIReader(try wire("input"))
    #expect(r.string() == "Coffee at Blue Bottle, $18.50")
    #expect(r.u32() == 8)

    // Field 0: a string with a description, stated nullable.
    #expect(r.string() == "merchant")
    #expect(r.u32() == 0)
    #expect(r.string() == "the shop or vendor")
    #expect(r.u32() == 1)

    // Field 1: a number carries its range and unit.
    #expect(r.string() == "amount")
    #expect(r.u32() == 1)
    #expect(r.string() == "total paid")
    #expect(r.u32() == 2)                     // nullable not stated
    #expect(r.u32() == 1); #expect(r.f64() == 0)
    #expect(r.u32() == 1); #expect(r.f64() == 10000)
    #expect(r.string() == "currency")

    // Field 2: a bare type string on the JS side means no describe, and a
    // nullable nobody stated.
    #expect(r.string() == "reimbursable")
    #expect(r.u32() == 2)
    #expect(r.string() == "")
    #expect(r.u32() == 2)

    // Field 3: label carries its value set inline.
    #expect(r.string() == "category")
    #expect(r.u32() == 4)
    #expect(r.string() == "")
    #expect(r.u32() == 2)
    #expect(r.strings() == ["food", "travel", "office"])

    // Field 4: datetime.
    #expect(r.string() == "when")
    #expect(r.u32() == 3)
    _ = r.string()
    #expect(r.u32() == 2)

    // Field 5: array, and `nullable: false` survives the crossing.
    #expect(r.string() == "attendees")
    #expect(r.u32() == 5)
    _ = r.string()
    #expect(r.u32() == 0)

    // Field 6: a number with neither bound nor unit.
    #expect(r.string() == "guests")
    #expect(r.u32() == 1)
    _ = r.string()
    #expect(r.u32() == 2)
    #expect(r.u32() == 0); _ = r.f64()
    #expect(r.u32() == 0); _ = r.f64()
    #expect(r.string() == "")

    // Field 7: an array of objects carries its properties inline, each in
    // the same field format.
    #expect(r.string() == "lines")
    #expect(r.u32() == 6)
    #expect(r.string() == "order lines")
    #expect(r.u32() == 2)
    #expect(r.u32() == 3)
    #expect(r.string() == "item"); #expect(r.u32() == 0); #expect(r.string() == "product")
    #expect(r.u32() == 2)
    #expect(r.string() == "quantity"); #expect(r.u32() == 1); #expect(r.string() == "")
    #expect(r.u32() == 2)
    #expect(r.u32() == 1); #expect(r.f64() == 1)
    #expect(r.u32() == 0); _ = r.f64()
    #expect(r.string() == "")
    #expect(r.string() == "size"); #expect(r.u32() == 4); #expect(r.string() == "")
    #expect(r.u32() == 0)
    #expect(r.strings() == ["S", "L"])
    #expect(r.isAtEnd)

    var o = FFIReader(try wire("options"))
    let anchor = o.string()
    #expect(anchor == "today=2026-07-05")
    // The anchor has to survive back into a Date, or pinned dates silently
    // become "today" and every relative datetime drifts.
    let date = try #require(Schemer.date(fromAnchor: anchor))
    #expect(Model.anchorString(date) == "today=2026-07-05")
}

/// The anchor is the day where the device is: 00:30 on the 5th in Berlin is
/// the 4th in UTC, and "yesterday" there means the 4th, not the 3rd. And a
/// pinned anchor comes back as the same day in every zone, the far ones too.
@Test func theAnchorIsTheDevicesDay() throws {
    let berlin = try #require(TimeZone(identifier: "Europe/Berlin"))
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = berlin
    let justAfterMidnight = try #require(cal.date(from: DateComponents(
        year: 2026, month: 7, day: 5, hour: 0, minute: 30)))
    #expect(Model.anchorString(justAfterMidnight, in: berlin) == "today=2026-07-05")
    #expect(Model.anchorString(justAfterMidnight, in: TimeZone(identifier: "UTC")!) == "today=2026-07-04")

    for id in ["Pacific/Kiritimati", "Pacific/Pago_Pago", "America/Sao_Paulo", "Asia/Kolkata", "UTC"] {
        let tz = try #require(TimeZone(identifier: id))
        let d = try #require(Schemer.date(fromAnchor: "today=2026-07-05", in: tz))
        #expect(Model.anchorString(d, in: tz) == "today=2026-07-05", "\(id)")
    }
}

/// The binding turns those bytes into the same `Field`s the Swift API builds,
/// including the difference between a stated and an unstated `nullable`, which
/// changes what the number and datetime heads are asked.
@Test func theBindingBuildsTheFieldsTheSwiftAPIWould() throws {
    let fields = try #require(SchemerBinding.fields(from: FFIReader(try wire("input"))))
    #expect(fields.text == "Coffee at Blue Bottle, $18.50")
    let expected: [Field] = [
        .string("merchant", describe: "the shop or vendor", nullable: true),
        .number("amount", describe: "total paid", min: 0, max: 10000, unit: "currency"),
        .boolean("reimbursable"),
        .label("category", values: ["food", "travel", "office"]),
        .datetime("when"),
        .array("attendees", nullable: false),
        .number("guests"),
        .objects("lines", properties: [
            .string("item", describe: "product"),
            .number("quantity", min: 1),
            .label("size", values: ["S", "L"], nullable: false),
        ], describe: "order lines"),
    ]
    #expect(fields.schema.fields == expected)
    #expect(fields.schema.fields[1].numberQuery
            == "amount: number \u{2014} total paid range 0..10000 unit: currency")
    #expect(fields.schema.fields[0].datetimeQuery.hasSuffix(" or null"))
    #expect(!fields.schema.fields[4].datetimeQuery.hasSuffix(" or null"))
}
#endif

/// The objects result kind, written by the binding's own writer, in the
/// layout packages/schemer-node's decoder reads.
@Test func objectsResultPayload() throws {
    var w = FFIWriter()
    Schemer.write(.objects([Record([("item", .string("desk")), ("quantity", .number(2))]),
                            Record([("item", .string("lamp"))])]), to: &w)
    var r = FFIReader(w.bytes)
    #expect(r.u32() == 7)
    #expect(r.u32() == 2)
    #expect(r.u32() == 2)
    #expect(r.string() == "item"); #expect(r.u32() == 1); #expect(r.string() == "desk")
    #expect(r.string() == "quantity"); #expect(r.u32() == 2); #expect(r.f64() == 2)
    #expect(r.u32() == 1)
    #expect(r.string() == "item"); #expect(r.u32() == 1); #expect(r.string() == "lamp")
    #expect(r.isAtEnd)
}

@Test func resultPayloadShapeMatchesTheJavaScriptDecoder() throws {
    // The kind tags the JS decoder switches on. Written here rather than
    // referenced so a renumbering on either side fails loudly.
    var w = FFIWriter()
    w.u32(3)
    w.u32(0)                       // null
    w.u32(2); w.f64(18.5)          // number
    w.u32(6); w.u32(2); w.string("Anna"); w.string("Bo")   // array

    var r = FFIReader(w.bytes)
    #expect(r.u32() == 3)
    #expect(r.u32() == 0)
    #expect(r.u32() == 2)
    #expect(r.f64() == 18.5)
    #expect(r.u32() == 6)
    #expect(r.strings() == ["Anna", "Bo"])
    #expect(r.isAtEnd)
}
