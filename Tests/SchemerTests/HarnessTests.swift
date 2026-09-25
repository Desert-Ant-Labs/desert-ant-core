// The harness is deterministic and needs no model, so these run everywhere
// and are the cheapest place to catch a locale regression.

import Testing
@testable import Schemer

@Suite struct NumberParsing {

    @Test("both thousands conventions")
    func conventions() {
        #expect(HarnessAPI.number("1,234.56") == 1234.56)   // en
        #expect(HarnessAPI.number("1.234,56") == 1234.56)   // de
        #expect(HarnessAPI.number("1 234,56") == 1234.56)   // fr
        #expect(HarnessAPI.number("320.000") == 320000)     // grouping, not decimal
        #expect(HarnessAPI.number("3.5") == 3.5)            // decimal, not grouping
    }

    @Test("scale words and CJK myriads")
    func scales() {
        #expect(HarnessAPI.number("9.5 million") == 9_500_000)
        #expect(HarnessAPI.number("950k") == 950_000)
        #expect(HarnessAPI.number("950\u{4e07}") == 9_500_000)
        #expect(HarnessAPI.number("2\u{4ebf}") == 200_000_000)
    }

    @Test("currency and percent are stripped")
    func symbols() {
        #expect(HarnessAPI.number("$18.50") == 18.5)
        #expect(HarnessAPI.number("\u{20ac}1.234,56") == 1234.56)
        #expect(HarnessAPI.number("12%") == 12)
    }

    @Test("a span with no number is absence, not a guess")
    func noNumber() {
        #expect(HarnessAPI.number("") == nil)
        #expect(HarnessAPI.number("reimbursable") == nil)
        #expect(HarnessAPI.number("$") == nil)
    }
}

@Suite struct Grounding {

    /// The span head points at a token, and a token boundary is not a literal
    /// boundary: on "1.234,56" it selects ".234,56", which parses to 234.56 and
    /// is off by 1000x. Snapping to a literal the text contains fixes it.
    @Test("snapping recovers a truncated literal")
    func snapping() {
        let text = "Rechnung von Siemens uber 1.234,56 EUR."
        let found = HarnessAPI.groundedNumbers(text)
        #expect(found.contains { $0.value == 1234.56 })
        let partial = found.first { $0.value == 1234.56 }!
        // The pointer landed one scalar late; the overlap still picks it.
        #expect(partial.start < partial.end)
    }

    @Test("finds every literal, in any script")
    func multi() {
        let g = HarnessAPI.groundedNumbers("Revenue hit 9.5 million, up from 950,000.")
        #expect(g.map(\.value) == [9_500_000, 950_000])
        #expect(HarnessAPI.groundedNumbers("\u{30d6}\u{30eb}\u{30fc}950\u{4e07}\u{5186}")
            .map(\.value) == [9_500_000])
        #expect(HarnessAPI.groundedNumbers("no numbers here").isEmpty)
    }
}

@Suite struct SpanTrimming {
    @Test func punctuation() {
        #expect(HarnessAPI.trim(" Bottle, ") == "Bottle")
        #expect(HarnessAPI.trim("\"quoted\"") == "quoted")
        #expect(HarnessAPI.trim("(aside)") == "aside")
        #expect(HarnessAPI.trim("Blue Bottle") == "Blue Bottle")
    }
}

@Suite struct SchemaValidation {
    @Test func duplicateNames() {
        #expect(throws: SchemerError.self) {
            try Schema([.string("a"), .number("a")]).validate()
        }
    }

    @Test func emptyLabelValues() {
        #expect(throws: SchemerError.self) {
            try Schema([.label("a", values: [])]).validate()
        }
    }

    @Test func tooManyLabelValues() {
        let many = (0..<64).map { "v\($0)" }
        #expect(throws: SchemerError.self) {
            try Schema([.label("a", values: many)]).validate()
        }
    }

    @Test("null renders as JSON null, not as a string")
    func jsonRendering() {
        let e = Extraction(values: [("a", .null), ("b", .string("x\"y")),
                                    ("c", .number(18.5)), ("d", .boolean(true)),
                                    ("e", .array(["p", "q"]))],
                           duration: 0)
        #expect(e.json.contains("\"a\": null"))
        #expect(e.json.contains("\"b\": \"x\\\"y\""))
        #expect(e.json.contains("\"c\": 18.5"))
        #expect(e.json.contains("\"d\": true"))
        #expect(e.json.contains("\"e\": [\"p\", \"q\"]"))
        #expect(e["a"].isNull)
    }
}
