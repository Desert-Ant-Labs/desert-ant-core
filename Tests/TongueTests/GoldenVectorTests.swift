// The vectors and the bundled model are SwiftPM resources, and `Bundle.module`
// has no WASI backing (the generated accessor traps rather than throws), so on
// wasm this whole suite is compiled out and test:wasi is a compile check for
// Tongue — the same shape every model's resource-reading tests take.
#if !os(WASI)
import Foundation
import Testing
@testable import Tongue

// The golden vectors are the cross-platform contract. The Python reference, this
// SDK, and the JavaScript port all replay the same files; if any of them drifts,
// the model sees different features on that platform and the implementations
// disagree silently. These tests exist so that drift fails loudly instead.
//
// Regenerate with `python scripts/gen_golden.py` in the training repo, in the
// same commit as any change to the normalizer, hasher or router spec.

struct GoldenVectorTests {
    // A missing resource is a packaging bug, so it fails rather than skipping
    // (the XCTest version skipped; Swift Testing has no runtime skip, and a
    // silently missing contract file is exactly the drift this suite exists
    // to catch).
    private func vectors(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"),
                               "\(name).json missing from the test bundle")
        return try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
            "\(name).json is not a JSON object")
    }

    @Test func normalizerMatchesReference() throws {
        let root = try vectors("normalize_vectors")
        let cases = root["cases"] as? [[String: Any]] ?? []
        #expect(!cases.isEmpty, "no normalizer cases loaded")
        for entry in cases {
            let input = entry["input"] as? String ?? ""
            let expected = entry["output"] as? String ?? ""
            #expect(
                Normalizer.normalize(input) == expected,
                "normalize(\(input.debugDescription)) diverged from the reference"
            )
        }
        // The cap is counted in Unicode scalars, matching Python's code-point
        // slice — not grapheme clusters and not UTF-16 units.
        if let cap = root["max_chars"] as? Int {
            #expect(Normalizer.maxCharacters == cap)
            let long = String(repeating: "é", count: cap + 50)
            #expect(Normalizer.normalize(long).unicodeScalars.count == cap)
        }
    }

    @Test func hasherMatchesReference() throws {
        let root = try vectors("hashing_vectors")
        #expect(Hashing.offsetBasis == UInt32(root["offset_basis"] as? Int ?? 0))
        #expect(Hashing.prime == UInt32(root["prime"] as? Int ?? 0))

        for entry in root["fnv1a"] as? [[String: Any]] ?? [] {
            let input = entry["input"] as? String ?? ""
            let expected = UInt32(entry["hash"] as? Int ?? 0)
            #expect(
                Hashing.fnv1a(input) == expected,
                "fnv1a(\(input.debugDescription)) diverged from the reference"
            )
        }

        // Whole-bag equality: catches boundary marking, n-gram order coverage and
        // the modulo, which per-string hashes alone would not.
        let buckets = root["num_buckets"] as? Int ?? 262_144
        let orders = root["ngram_orders"] as? [Int] ?? Hashing.ngramOrders
        for entry in root["bags"] as? [[String: Any]] ?? [] {
            let normalized = entry["normalized"] as? String ?? ""
            let expected = (entry["bag"] as? [String: Int] ?? [:])
                .reduce(into: [Int: Int]()) { $0[Int($1.key) ?? -1] = $1.value }
            let actual = Hashing.buckets(normalized, numBuckets: buckets, orders: orders)
            #expect(actual == expected, "bag for \(normalized.debugDescription) diverged")
        }
    }

    @Test func routerMatchesReference() throws {
        let cases = try vectors("script_vectors")["cases"] as? [[String: Any]] ?? []
        #expect(!cases.isEmpty, "no router cases loaded")
        for entry in cases {
            let input = entry["input"] as? String ?? ""
            let normalized = Normalizer.normalize(input)
            #expect(normalized == entry["normalized"] as? String ?? normalized,
                    "normalization diverged before routing \(input.debugDescription)")

            let route = Router.route(normalized)
            #expect(route.verdict.rawValue == entry["verdict"] as? String ?? "",
                    "verdict diverged for \(input.debugDescription)")
            #expect(route.candidates == entry["candidates"] as? [String] ?? [],
                    "candidates diverged for \(input.debugDescription)")
            if let expectedScript = entry["script"] as? String {
                #expect(route.script?.rawValue == expectedScript,
                        "script diverged for \(input.debugDescription)")
            } else {
                #expect(route.script == nil, "expected no script for \(input.debugDescription)")
            }
        }
    }

    /// Replays detection_vectors.json — the head's output, which nothing asserted
    /// before. Every other stage had vectors, so the three ports could disagree on
    /// `language` for hashtag input while all three suites stayed green.
    ///
    /// Generated by scripts/gen_detection_vectors.py, a fourth implementation of
    /// the documented arithmetic reading the shipped weights, so agreement here is
    /// between four independent implementations. Probabilities carry a tolerance
    /// because `exp` differs in the last bits between libms; the discrete fields
    /// are exact.
    @Test func detectionMatchesReferenceHead() throws {
        let root = try vectors("detection_vectors")
        let tolerance = root["tolerance"] as? Double ?? 1e-6
        let cases = root["cases"] as? [[String: Any]] ?? []
        #expect(!cases.isEmpty, "no detection cases loaded")

        let tongue = try Tongue()
        for testCase in cases {
            let input = testCase["input"] as? String ?? ""
            let detection = tongue.detect(input)
            #expect(detection.normalized == testCase["normalized"] as? String, "normalized for \(input)")
            #expect(detection.language == testCase["language"] as? String, "language for \(input)")
            #expect(detection.reliability.rawValue == testCase["reliability"] as? String,
                    "reliability for \(input)")
            #expect(detection.isTooCloseToCall == testCase["isTooCloseToCall"] as? Bool,
                    "isTooCloseToCall for \(input)")

            let languages = testCase["candidateLanguages"] as? [String] ?? []
            let probabilities = testCase["candidateProbabilities"] as? [Double] ?? []
            #expect(detection.candidates.count == languages.count, "candidate count for \(input)")
            for (index, language) in languages.enumerated() where index < detection.candidates.count {
                #expect(detection.candidates[index].language == language,
                        "candidate \(index) for \(input)")
                #expect(abs(detection.candidates[index].probability - probabilities[index]) <= tolerance,
                        "probability \(index) for \(input)")
            }
        }
    }

}

struct DetectionTests {
    // The bundled model is a packaged resource; failing to load it is a
    // packaging bug, so `Tongue()` throwing fails the test rather than
    // skipping it as the XCTest version did.
    @Test func detectsAcrossScripts() throws {
        let tongue = try Tongue()
        let expectations: [(String, String)] = [
            ("je voudrais un café au lait", "fr"),
            ("kann ich das haben", "de"),
            ("muchas gracias por la ayuda", "es"),
            ("привет как твои дела", "ru"),
            ("안녕하세요 만나서 반갑습니다", "ko"),
            ("こんにちは、お元気ですか", "ja"),
            ("مرحبا كيف حالك اليوم", "ar"),
            ("the garage sale is on saturday morning", "en"),
        ]
        for (text, expected) in expectations {
            #expect(tongue.detect(text).language == expected,
                    "detect(\(text.debugDescription))")
        }
    }

    @Test func reportsTooCloseToCallRatherThanGuessing() throws {
        let tongue = try Tongue()
        // "la casa" is equally Italian and Spanish; presenting one would be a lie.
        let detection = tongue.detect("la casa")
        #expect(detection.isTooCloseToCall)
        #expect(detection.reliability == .tentative)
    }

    @Test func shortInputIsNotReportedConfident() throws {
        let tongue = try Tongue()
        // Reads as Welsh to any character model. The point is that it says so.
        #expect(tongue.detect("hi i am").reliability == .tentative)
    }

    @Test func emptyInput() throws {
        let tongue = try Tongue()
        let detection = tongue.detect("   ")
        #expect(detection.reliability == .empty)
        #expect(detection.language == nil)
    }
}
#endif
