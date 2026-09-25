// Intermediate decisions, exposed for conformance testing, plus the
// deterministic harness.
//
// `extract` returns values; a port that disagrees with the reference needs to
// know WHERE, and re-deriving that from a JSON string is guesswork. This runs
// the same work `extract` does and keeps the head outputs.

import DesertAnt
import Foundation

extension Model {

    /// What one field's heads decided, before the harness turned it into a
    /// value.
    struct FieldTrace: Sendable {
        var tokenCount: Int
        var textStart: Int
        var boolLogits: [Float]
        var stringPresenceAbsent: Float
        var arrayPresenceAbsent: Float
        var stringBIOTags: [Int]
        var arrayBIOTags: [Int]
        var spanStart: Int
        var spanEnd: Int
        var dtNull: Float
        var numNull: Float
        var dtYear: Int, dtMonth: Int, dtDay: Int, dtHour: Int, dtMinute: Int
        var value: Value
    }

    /// Run one field and keep the intermediates.
    func trace(text: String, field: Field, anchor: String,
               resolveAnchor: DateComponents? = nil,
               trustedAnchor: Bool = true) async throws -> FieldTrace {
        let s = try await stage(text: text, field: field, anchor: anchor)
        let h = s.heads

        func tags(_ key: String) -> [Int] {
            let f = h[key], T = s.window
            return (s.textStart..<s.validEnd).map { t in
                var best = 0
                for k in 1..<3 where f[k * T + t] > f[best * T + t] { best = k }
                return best
            }
        }
        let start = h["span_start"], end = h["span_end"]
        let sp = h["string_presence"], ap = h["array_presence"]

        return FieldTrace(
            tokenCount: s.validEnd, textStart: s.textStart,
            boolLogits: Array(h["bool_logits"].prefix(3)),
            stringPresenceAbsent: Harness.softmax2(sp[1], sp[0]),
            arrayPresenceAbsent: Harness.softmax2(ap[1], ap[0]),
            stringBIOTags: tags("string_bio"), arrayBIOTags: tags("array_bio"),
            spanStart: s.textStart + Harness.argmax(start[s.textStart..<s.validEnd]),
            spanEnd: s.textStart + Harness.argmax(end[s.textStart..<s.validEnd]),
            dtNull: h["dt_null"].first ?? 0, numNull: h["num_null"].first ?? 0,
            dtYear: h.argmax("dt_year", 256), dtMonth: h.argmax("dt_month", 12),
            dtDay: h.argmax("dt_day", 31), dtHour: h.argmax("dt_hour", 24),
            dtMinute: h.argmax("dt_minute", 60),
            value: try await decodeValue(s, text: text, field: field, modelAnchor: anchor,
                                         resolveAnchor: resolveAnchor,
                                         trustedAnchor: trustedAnchor))
    }
}

/// The deterministic harness, exposed so a port can be conformance-tested
/// against `harness/*.json` without running any model.
enum HarnessAPI {
    /// Parse a numeric literal under any supported locale convention.
    static func number(_ s: String) -> Double? { Harness.number(s) }

    /// Every numeric literal in the text, with scalar offsets.
    static func groundedNumbers(_ s: String) -> [(value: Double, start: Int, end: Int)] {
        Harness.groundedNumbers(s).map { ($0.value, $0.start, $0.end) }
    }

    /// Boundary cleanup applied to every extracted span.
    static func trim(_ s: String) -> String { Harness.trim(s) }
}

/// Tokenizer conformance surface, so a port can be checked without linking
/// the test target.
struct TokenizerCheck: Sendable {
    let ids: [Int32], slim: [Int32], offsets: [[Int]], decoded: String
}

/// A loaded tokenizer. Loading parses an 11 MB sidecar, so a conformance run
/// must hold one of these rather than reloading per case.
final class TokenizerHandle: @unchecked Sendable {
    private let t: SchemerTokenizer
    init(bundle: URL) throws {
        t = try SchemerTokenizer(sidecar: bundle.appendingPathComponent(SchemerModel.tokenizer))
    }
    func check(_ text: String, maxLength: Int = 8192) -> TokenizerCheck {
        let e = t.encode(text, maxLength: maxLength)
        let ids = e.map(\.id)
        return TokenizerCheck(ids: ids, slim: t.slim(ids),
                              offsets: e.map { [$0.start, $0.end] }, decoded: t.decode(ids))
    }
}
