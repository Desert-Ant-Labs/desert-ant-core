// The nested harness with no model in the loop: segmentation and assembly are
// string and set logic, so the port is checked against what the reference's
// own functions return (`Resources/schemer_segments.json`, from
// schemer-training's tools/release/dump_segment_fixtures.py). Runs everywhere.

import Foundation
import Testing
@testable import Schemer

#if !os(WASI)  // bundle resources are not readable under the wasm test harness
private struct Fixture: Decodable {
    struct Segmented: Decodable { let text: String; let segments: [String] }
    struct Deduped: Decodable {
        let objects: [[String: Golden.Answer]]
        let kept: [[String: Golden.Answer]]
    }
    struct Spanning: Decodable {
        let text: String
        let anchor: String
        /// `[segment, object]` pairs, as the reference collects them.
        let found: [[Candidate]]
        let kept: [[String: Golden.Answer]]
    }
    enum Candidate: Decodable {
        case segment(String), object([String: Golden.Answer])
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .segment(s) }
            else { self = .object(try c.decode([String: Golden.Answer].self)) }
        }
    }
    struct SoleTime: Decodable { let text: String; let time: [Int]? }
    let segment: [Segmented]
    let dedupe: [Deduped]
    let spanning: [Spanning]
    let soleTime: [SoleTime]
    enum CodingKeys: String, CodingKey { case segment, dedupe, spanning, soleTime = "sole_time" }

    static func load() throws -> Fixture {
        let url = try #require(Bundle.module.url(forResource: "schemer_segments", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}

private func value(_ a: Golden.Answer) -> Value {
    switch a {
    case .null: .null
    case .string(let s): .string(s)
    case .number(let d): .number(d)
    case .boolean(let b): .boolean(b)
    case .array(let xs): .array(xs)
    case .objects: .null
    }
}

/// JSON objects are unordered; the reference's own order is its schema order,
/// so sorting the keys is enough to feed the port the same items.
private func record(_ o: [String: Golden.Answer]) -> Record {
    Record(o.keys.sorted().map { ($0, value(o[$0]!)) })
}

struct NestedHarness {
    @Test func segmentationMatchesTheReference() throws {
        let fx = try Fixture.load()
        #expect(fx.segment.count > 60)
        for c in fx.segment {
            #expect(Nested.segment(c.text) == c.segments, "\(c.text.debugDescription)")
        }
    }

    @Test func assemblyMatchesTheReference() throws {
        for c in try Fixture.load().dedupe {
            let kept = Nested.dedupe(c.objects.map(record))
            #expect(kept == c.kept.map(record), "\(c.objects.count) objects")
        }
    }

    @Test func spanningCandidatesMatchTheReference() throws {
        let cases = try Fixture.load().spanning
        #expect(cases.count >= 5)
        for c in cases {
            let found = c.found.map { pair -> (segment: String, anchor: Value, record: Record) in
                guard case .segment(let seg) = pair[0], case .object(let o) = pair[1] else {
                    Issue.record("malformed fixture"); return ("", .null, Record([]))
                }
                return (seg, value(o[c.anchor]!), record(o))
            }
            #expect(Nested.dropSpanning(found, in: c.text) == c.kept.map(record),
                    "\(c.text.debugDescription)")
        }
    }

    /// Not nested, but the same kind of check: the stated-time parser that
    /// overrides the datetime head's time, against the reference's own.
    @Test func statedTimesMatchTheReference() throws {
        let cases = try Fixture.load().soleTime
        #expect(cases.count > 30)
        for c in cases {
            let t = RelativeDates.soleTimeOfDay(c.text).map { [$0.0, $0.1] }
            #expect(t == c.time, "\(c.text.debugDescription)")
        }
    }

    @Test func anchorIsTheFirstStringProperty() {
        #expect(Nested.anchor([.number("n"), .string("a"), .string("b")]).name == "a")
        #expect(Nested.anchor([.number("n"), .boolean("b")]).name == "n")
    }
}
#endif
