// Field-level conformance against the reference on EVAL records.
//
// The committed golden (`schemer_golden.json`) is written for the purpose,
// because this repository is public. This is the stronger internal check it
// stands in for: `reference_fixtures.json` records what the unmodified
// `predict_for_schema` returned on held-out eval records running on the
// exported graphs (schemer-training's tools/release/dump_reference_fixtures.py),
// so it lives in the training repo's release bundle, not here. Opt in with
//
//     SCHEMER_REFERENCE_FIXTURES=<reference_fixtures.json> SCHEMER_MODEL_DIR=<dir> \
//       swift test --disable-xctest --filter conformance
//
// The predecessor of that fixture compared the SDK against a Python *port* of
// the harness. Both were written from the same misreading of the offset
// mapping, so it passed 180/180 while both extracted "Bottle" where the
// reference extracts "Blue Bottle". A fixture is only worth what its source
// is; this one's source is the model of record.

import Foundation
import Testing
@_spi(SchemerBindings) @testable import Schemer

private struct Ref: Decodable {
    struct Spec: Decodable {
        let type: String
        let describe: String?
        let values: [String]?
        let nullable: Bool?
        /// The eval corpus carries `mode` ("identifier", "generate", ...) and
        /// the reference returns "" for anything but "extract". `Schema`
        /// cannot express a mode, so those fields are not a contract on the
        /// SDK and are skipped rather than matched.
        let mode: String?
        let min: Double?
        let max: Double?
        let unit: String?
        struct Items: Decodable { let properties: [String: Spec]? }
        let items: Items?
    }
    struct Case: Decodable {
        let id: String?, lang: String?, anchor: String, text: String
        /// Whether the record CARRIED an anchor. The datetime harness only
        /// lets a real anchor overwrite the decoded year; a record without one
        /// is shown a default, which must not.
        let anchor_trusted: Bool?
        let schema: [String: Spec]
        let expected: [String: Val]
        /// Each array of objects' property order, which a map loses.
        let property_order: [String: [String]]?
        /// What a nested segment was encoded with. The reference shows a
        /// segment its default anchor, untrusted, whatever the record carried.
        let segment_anchor: String?
        let segment_anchor_trusted: Bool?
    }
    indirect enum Val: Decodable, Equatable {
        case null, string(String), number(Double), boolean(Bool), array([String])
        case objects([[String: Val]])
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if c.decodeNil() { self = .null }
            else if let v = try? c.decode(Bool.self) { self = .boolean(v) }
            else if let v = try? c.decode(Double.self) { self = .number(v) }
            else if let v = try? c.decode(String.self) { self = .string(v) }
            else if let v = try? c.decode([String].self) { self = .array(v) }
            else if let v = try? c.decode([[String: Val]].self) { self = .objects(v) }
            else { self = .null }
        }
    }
    let cases: [Case]
}

private func normalize(_ v: Value) -> Ref.Val {
    switch v {
    case .null: return .null
    case .string(let s), .datetime(let s), .label(let s): return .string(s)
    case .number(let d): return .number(d)
    case .boolean(let b): return .boolean(b)
    case .array(let xs): return .array(xs)
    case .objects(let items):
        return .objects(items.map { item in
            Dictionary(uniqueKeysWithValues: item.entries.map { ($0.name, normalize($0.value)) })
        })
    }
}

private func same(_ a: Ref.Val, _ b: Ref.Val) -> Bool {
    if case .number(let x) = a, case .number(let y) = b { return abs(x - y) < 1e-6 }
    // The reference writes "" for an absent non-nullable string; that and
    // null are the same answer, not a disagreement.
    if case .string(let x) = a, x.isEmpty, case .null = b { return true }
    if case .null = a, case .string(let y) = b, y.isEmpty { return true }
    if case .objects(let x) = a, case .array(let y) = b { return x.isEmpty && y.isEmpty }
    if case .objects(let x) = a, case .objects(let y) = b {
        return x.count == y.count && zip(x, y).allSatisfy { p, q in
            p.keys.sorted() == q.keys.sorted() && p.allSatisfy { k, v in same(v, q[k]!) }
        }
    }
    return a == b
}

private func field(_ name: String, _ s: Ref.Spec) -> Field {
    let d = s.describe, n = s.nullable
    switch s.type {
    case "number": return .number(name, describe: d, nullable: n,
                                  min: s.min, max: s.max, unit: s.unit)
    case "boolean": return .boolean(name, describe: d, nullable: n)
    case "datetime": return .datetime(name, describe: d, nullable: n)
    case "array": return .array(name, describe: d, nullable: n)
    case "label": return .label(name, values: s.values ?? [], describe: d, nullable: n)
    default: return .string(name, describe: d, nullable: n)
    }
}

private let fixturesPath = ProcessInfo.processInfo.environment["SCHEMER_REFERENCE_FIXTURES"]

#if !os(WASI)
@Test(.enabled(if: fixturesPath != nil, "set SCHEMER_REFERENCE_FIXTURES to run the eval-record conformance"))
func conformanceAgainstReference() async throws {
    let url = URL(fileURLWithPath: try #require(fixturesPath))
    let fx = try JSONDecoder().decode(Ref.self, from: Data(contentsOf: url))
    let schemer = try await SchemerFixture.schemer()

    var total = 0, match = 0, skipped = 0
    var byType: [String: (hit: Int, n: Int)] = [:]
    for c in fx.cases {
        for name in c.schema.keys.sorted() {
            guard let spec = c.schema[name] else { continue }
            if let m = spec.mode, m != "extract" { skipped += 1; continue }
            if spec.type == "label",
               (spec.values?.count ?? 0) > Schemer.maxLabelValues { skipped += 1; continue }
            let type: String
            let got: Ref.Val
            if let props = spec.items?.properties {
                type = "objects"
                let order = try #require(c.property_order?[name], "\(name): no property order")
                got = normalize(try await schemer.objects(
                    text: c.text, properties: order.map { field($0, props[$0]!) },
                    anchor: try #require(c.segment_anchor),
                    trustedAnchor: c.segment_anchor_trusted ?? false))
            } else {
                type = spec.type
                got = normalize(try await schemer.trace(
                    text: c.text, field: field(name, spec), anchor: c.anchor,
                    trustedAnchor: c.anchor_trusted ?? true).value)
            }
            total += 1
            var e = byType[type] ?? (0, 0)
            e.n += 1
            if same(got, c.expected[name] ?? .null) { match += 1; e.hit += 1 }
            else if type == "objects" {
                print("  \(c.id ?? "?").\(name): got \(got), reference \(c.expected[name] ?? .null)")
            }
            byType[type] = e
        }
    }
    let pct = 100.0 * Double(match) / Double(max(1, total))
    print("conformance vs reference: \(match)/\(total) fields "
          + "(\(String(format: "%.1f", pct))%), \(skipped) skipped")
    for (t, v) in byType.sorted(by: { $0.key < $1.key }) {
        print("   \(t): \(v.hit)/\(v.n)")
    }
    // Every type exactly: 732/732 on the 1.0.0 graphs for the flat types.
    #expect(match == total, "\(match)/\(total) (\(String(format: "%.1f", pct))%)")
    for (t, v) in byType { #expect(v.hit == v.n, "\(t): \(v.hit)/\(v.n)") }
}
#endif
