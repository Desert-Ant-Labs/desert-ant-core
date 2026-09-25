import Foundation
import Testing
import DesertAnt
import TestSupport
@_spi(SchemerBindings) @testable import Schemer

// MARK: no model

/// The public API rejects a bad schema before it loads anything, so a caller
/// learns about a typo without paying for a model load (or lacking a network).
struct PublicAPIValidation {
    @Test func rejectsBeforeLoading() async {
        let schemer = Schemer(directory: "/nonexistent")
        await #expect(throws: SchemerError.self) {
            try await schemer.extract(from: "x", schema: [.label("k", values: [])])
        }
        await #expect(throws: SchemerError.self) {
            try await schemer.extract(
                from: "x", schema: [.label("k", values: (0...Schemer.maxLabelValues).map { "v\($0)" })])
        }
        await #expect(throws: SchemerError.self) {
            try await schemer.extract(from: "x", schema: [.string("a"), .number("a")])
        }
        await #expect(throws: SchemerError.self) {
            try await schemer.extract(from: "x", schema: [.string("")])
        }
        // Objects are validated all the way down, and do not nest.
        await #expect(throws: SchemerError.self) {
            try await schemer.extract(from: "x", schema: [
                .objects("o", properties: [.string("a"), .string("a")])])
        }
        await #expect(throws: SchemerError.self) {
            try await schemer.extract(from: "x", schema: [
                .objects("o", properties: [.label("k", values: [])])])
        }
        await #expect(throws: SchemerError.self) {
            try await schemer.extract(from: "x", schema: [
                .objects("o", properties: [.objects("inner", properties: [.string("a")])])])
        }
        // Number bounds must be finite and in order.
        for field: Field in [.number("n", min: .nan), .number("n", max: .infinity),
                             .number("n", min: 5, max: 1)] {
            await #expect(throws: SchemerError.self) {
                try await schemer.extract(from: "x", schema: [field])
            }
        }
    }

    /// A corrupt self-hosted sidecar throws `invalidBundle` instead of trapping
    /// or allocating what its header claims.
    @Test func corruptSidecarsThrow() {
        func le(_ xs: [UInt32]) -> Data {
            Data(xs.flatMap { x in (0..<4).map { UInt8(truncatingIfNeeded: x >> (8 * $0)) } })
        }
        let header = Data("SCTK".utf8) + le([1, 0, 1, 2, 3])
        for tail in [Data(), le([0xFFFF_FFFF]), le([1, 1_000_000]), le([1, 3]) + Data("ab".utf8),
                     le([0, 0, 0, 0, 0, 0, 0, 0xFFFF_FFFF])] {
            #expect(throws: SchemerError.self) { try SchemerTokenizer(data: header + tail) }
        }
        #expect(throws: SchemerError.self) { try SchemerTokenizer(data: Data("SCT".utf8)) }

        let embed = Data("SCEM".utf8)
        for (vocab, dim): (UInt32, UInt32) in [(0xFFFF_FFFF, 0xFFFF_FFFF), (4, 0), (4, 3), (4, 8)] {
            #expect(throws: SchemerError.self) {
                try EmbeddingTable(data: embed + le([1, 8, vocab, dim]) + Data(count: 8))
            }
        }
    }

    /// A stated nullable reaches the number and datetime heads' own queries,
    /// which is why the bindings keep "not stated" distinct from true.
    @Test func statedNullableChangesTheHeadQueries() {
        #expect(Field.number("n").numberQuery == "n: number")
        #expect(Field.number("n", nullable: true).numberQuery == "n: number or null")
        #expect(Field.number("n", nullable: false).numberQuery == "n: number")
        #expect(Field.datetime("d", describe: "due").datetimeQuery == "d: datetime \u{2014} due")
        #expect(Field.datetime("d", nullable: true).datetimeQuery == "d: datetime or null")
        #expect(Field.number("p", min: 0, max: 100000, unit: "currency").numberQuery
                == "p: number range 0..100000 unit: currency")
        #expect(Field.number("p", min: 0.5).numberQuery == "p: number range 0.5..None")
    }

    @Test func everyKindRendersAsJSON() {
        let e = Extraction(values: [
            ("s", .string("q\"uote\n")), ("n", .number(18.5)), ("i", .number(3)),
            ("b", .boolean(false)), ("d", .datetime("2026-03-11T09:30")),
            ("l", .label("food")), ("a", .array(["Anna", "Bo"])),
        ], duration: 0)
        #expect(e.json == """
            {
              "s": "q\\"uote\\n",
              "n": 18.5,
              "i": 3,
              "b": false,
              "d": "2026-03-11T09:30",
              "l": "food",
              "a": ["Anna", "Bo"]
            }
            """)
        #expect(e["n"] == .number(18.5))
        #expect(e["missing"] == .null)
        #expect(e.dictionary.count == 7)
    }
}

// MARK: through the model

#if !os(WASI)
@Suite(.serialized, .enabled(if: SchemerFixture.runs, "model-backed tests do not run on iOS or Android"))
struct SchemerModelTests {
    /// Every golden case through the public API, against what the reference
    /// harness returns on this platform's graphs. Per field, not a score: every
    /// head feeds an argmax or a threshold, and the reference ran the same
    /// graphs. See `Golden.allowedDisagreements` for the few fields other
    /// hardware may round the other way.
    @Test func matchesTheReferenceOnEveryGoldenCase() async throws {
        let golden = try Golden.load()
        #expect(golden.revision == SchemerModel.revision,
                "the golden was generated for another revision's graphs")
        let schemer = try await SchemerFixture.schemer()
        var fields = 0
        var disagreements: [String] = []
        for c in golden.cases {
            let out = try await schemer.extract(from: c.text, schema: c.schemaValue, now: c.date)
            #expect(out.values.map(\.field) == c.schema.map(\.name), "\(c.id): schema order")
            for spec in c.schema {
                let want = try #require(c.answers[spec.name], "\(c.id).\(spec.name) has no answer")
                let got = Golden.Answer(out[spec.name])
                if !got.matches(want) {
                    disagreements.append("\(c.id).\(spec.name): got \(got), reference \(want)")
                }
                fields += 1
            }
        }
        #expect(fields > 100)
        for d in disagreements { print("schemer differs from the reference: \(d)") }
        #expect(disagreements.count <= Golden.allowedDisagreements(of: fields),
                "\(disagreements.count) of \(fields) fields differ:\n\(disagreements.joined(separator: "\n"))")
    }

    /// The types come back typed: a label is one of the declared values, a
    /// string is a literal substring of the input.
    @Test func valuesAreTypedByConstruction() async throws {
        let golden = try Golden.load()
        let schemer = try await SchemerFixture.schemer()
        func check(_ value: Value, _ spec: Golden.FieldSpec, _ c: Golden.Case) {
            switch value {
            case .label(let v): #expect(spec.values?.contains(v) == true, "\(c.id).\(spec.name)")
            case .string(let s): #expect(c.text.contains(s), "\(c.id).\(spec.name): \(s)")
            case .array(let xs):
                for x in xs { #expect(c.text.contains(x), "\(c.id).\(spec.name): \(x)") }
            case .objects(let items):
                let properties = spec.items?.properties ?? []
                #expect(items.count <= 16, "\(c.id).\(spec.name)")
                for item in items {
                    // Only declared properties, in schema order, none empty.
                    let order = properties.map(\.name).filter(item.names.contains)
                    #expect(item.names == order, "\(c.id).\(spec.name): \(item.names)")
                    for (name, v) in item.entries {
                        #expect(!v.isNull, "\(c.id).\(spec.name).\(name)")
                        if let p = properties.first(where: { $0.name == name }) { check(v, p, c) }
                    }
                }
            case .number, .boolean, .datetime, .null: break
            }
        }
        for c in golden.cases {
            let out = try await schemer.extract(from: c.text, schema: c.schemaValue, now: c.date)
            for spec in c.schema { check(out[spec.name], spec, c) }
        }
    }

    /// An array of objects renders as JSON objects inside the array, with
    /// only the properties each item states.
    @Test func objectsRenderAsJSON() {
        let e = Extraction(values: [
            ("lines", .objects([Record([("item", .string("chairs")), ("quantity", .number(2))]),
                                Record([("item", .string("desk"))])])),
            ("none", .objects([])),
        ], duration: 0)
        #expect(e.json == """
            {
              "lines": [{"item": "chairs", "quantity": 2}, {"item": "desk"}],
              "none": []
            }
            """)
    }

    /// The record the README leads with, end to end.
    @Test func readmeExample() async throws {
        let schemer = try await SchemerFixture.schemer()
        let out = try await schemer.extract(
            from: "Coffee meeting at Blue Bottle with Dana and Priya, $18.50 on the company card. Reimbursable.",
            schema: [
                .string("merchant", describe: "the shop or vendor"),
                .number("amount", describe: "total paid", unit: "currency"),
                .boolean("reimbursable"),
                .label("category", values: ["food", "travel", "office"]),
                .array("attendees", describe: "people present"),
            ],
            now: Schemer.date(fromAnchor: "today=2026-03-10")!)
        #expect(out["merchant"] == .string("Blue Bottle"))
        #expect(out["amount"] == .number(18.5))
        #expect(out["reimbursable"] == .boolean(true))
        #expect(out["category"] == .label("food"))
        #expect(out["attendees"] == .array(["Dana", "Priya"]))
    }

    /// Relative dates resolve against `now`, so pinning it pins the answer.
    @Test func nowPinsRelativeDates() async throws {
        let schemer = try await SchemerFixture.schemer()
        let schema: Schema = [.datetime("when", describe: "when to be reminded")]
        let text = "Remind me to call the dentist tomorrow at 9:30."
        let a = try await schemer.extract(from: text, schema: schema,
                                          now: Schemer.date(fromAnchor: "today=2026-03-10")!)
        let b = try await schemer.extract(from: text, schema: schema,
                                          now: Schemer.date(fromAnchor: "today=2026-12-31")!)
        #expect(a["when"] == .datetime("2026-03-11T09:30"))
        #expect(b["when"] == .datetime("2027-01-01T09:30"))
    }

    @Test func emptySchemaAndEmptyText() async throws {
        let schemer = try await SchemerFixture.schemer()
        #expect(try await schemer.extract(from: "anything", schema: []).values.isEmpty)
        let out = try await schemer.extract(from: "", schema: [.string("name", nullable: true)])
        #expect(out["name"] == .null)
    }

    /// Past the longest window the text is truncated, not rejected.
    @Test func textLongerThanTheLongestWindow() async throws {
        let schemer = try await SchemerFixture.schemer()
        let long = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 400)
            + "The invoice total is $42."
        let out = try await schemer.extract(from: long, schema: [.number("total", nullable: true)])
        #expect(out.values.count == 1)
        // The total is past the window, which the result says.
        #expect(out.truncated)
        let short = try await schemer.extract(from: "The invoice total is $42.",
                                              schema: [.number("total", nullable: true)])
        #expect(!short.truncated)
    }

    /// Callers share one extractor across tasks.
    @Test func concurrentExtractionsAgree() async throws {
        let golden = try Golden.load()
        let schemer = try await SchemerFixture.schemer()
        let cases = Array(golden.cases.prefix(6))
        let serial = try await cases.asyncMap {
            try await schemer.extract(from: $0.text, schema: $0.schemaValue, now: $0.date).json
        }
        let parallel = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (i, c) in cases.enumerated() {
                // Sendable values only: the golden case itself is not.
                let text = c.text, schema = c.schemaValue, now = c.date
                group.addTask {
                    (i, try await schemer.extract(from: text, schema: schema, now: now).json)
                }
            }
            var out = [String](repeating: "", count: cases.count)
            for try await (i, json) in group { out[i] = json }
            return out
        }
        #expect(parallel == serial)
    }

    /// Hundreds of fields in one process. Core ML hands outputs back as
    /// IOSurface-backed arrays, and a caller looping in one task used to hold
    /// them until the Neural Engine could not allocate another: an uncaught
    /// "Failed to allocate E5 buffer object" after ~500 fields.
    @Test func sustainedUseDoesNotExhaustTheRuntime() async throws {
        let golden = try Golden.load()
        let schemer = try await SchemerFixture.schemer()
        var fields = 0
        while fields < 700 {
            for c in golden.cases where c.text.count < 400 {
                _ = try await schemer.extract(from: c.text, schema: c.schemaValue, now: c.date)
                fields += c.schema.count
            }
        }
    }

    @Test func prewarmIsIdempotent() async throws {
        let schemer = try await SchemerFixture.schemer()
        try await schemer.prewarm()
        try await schemer.prewarm()
    }

    /// The tokenizer reproduces the HF fast tokenizer bit for bit: ids,
    /// because the model was trained on exactly those, and offsets, because
    /// they are how a span is sliced back out of the caller's string.
    @Test func tokenizerMatchesTheReference() async throws {
        struct Fixtures: Decodable {
            struct Case: Decodable {
                let id: String
                let text: String?
                let ids: [Int32], slim_ids: [Int32], offsets: [[Int]], decoded: String?
                let max_length: Int?
            }
            let cases: [Case]
        }
        let url = try #require(Bundle.module.url(forResource: "schemer_tokenizer_fixtures",
                                                 withExtension: "json"))
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
        let tokenizer = try TokenizerHandle(bundle: try await SchemerFixture.files())
        var checked = 0
        for c in fixtures.cases {
            guard let text = c.text else { continue }
            let r = tokenizer.check(text, maxLength: c.max_length ?? 1216)
            #expect(r.ids == c.ids, "\(c.id): ids")
            #expect(r.slim == c.slim_ids, "\(c.id): remapped ids")
            #expect(r.offsets == c.offsets, "\(c.id): offsets")
            if let want = c.decoded { #expect(r.decoded == want, "\(c.id): decode") }
            checked += 1
        }
        #expect(checked > 400)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        out.reserveCapacity(count)
        for e in self { out.append(try await transform(e)) }
        return out
    }
}
#endif
