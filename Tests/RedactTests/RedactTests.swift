import Foundation
import Testing
import DesertAnt
import TestSupport
@testable import Redact

/// Thread-safe Double for capturing progress across concurrency domains.
final class LockedDouble: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    func set(_ v: Double) { lock.withLock { value = v } }
    func get() -> Double { lock.withLock { value } }
}

struct RedactTests {
    // MARK: deterministic recognizers (no model needed)

    @Test func emailAndURL() {
        let spans = Deterministic.detect("Reach me at anna.k@example.com or https://ex.com/x")
        let labels = Set(spans.map(\.label))
        #expect(labels.contains("EMAIL"))
        #expect(labels.contains("URL"))
    }

    @Test func creditCardIsLuhnGated() {
        // valid Luhn + context means detected
        let ok = Deterministic.detect("charge my card 4539 1488 0343 6467")
        #expect(ok.contains { $0.label == "CREDIT_CARD" })
        // invalid Luhn means not a credit card
        let bad = Deterministic.detect("card 1234 5678 9012 3456")
        #expect(!bad.contains { $0.label == "CREDIT_CARD" })
    }

    @Test func ibanChecksum() {
        let ok = Deterministic.detect("IBAN GB29 NWBK 6016 1331 9268 19")
        #expect(ok.contains { $0.label == "BANK_ACCOUNT" })
    }

    @Test func usStreetAndState() {
        let t = UTF16Text("mailed to 123 Any Street, Seattle, WA 98109")
        let spans = Pipeline.attachStateCodes(t, Pipeline.redactUsStreet(t, []))
        let byLabel = Dictionary(grouping: spans) { $0.label }
        #expect(byLabel["BUILDING_NUMBER"]?.count == 1)
        #expect(byLabel["STREET_NAME"]?.contains { t.slice($0.start, $0.end) == "Any Street" } ?? false)
        #expect(byLabel["STATE"]?.contains { t.slice($0.start, $0.end) == "WA" } ?? false)
    }

    @Test func secondaryAddress() {
        let t = UTF16Text("123 Main St, Apt 4B")
        let spans = Pipeline.redactSecondaryAddress(t, [])
        #expect(spans.contains { $0.label == "SECONDARY_ADDRESS" && t.slice($0.start, $0.end) == "Apt 4B" })
        // precision: ordinary prose is left alone
        let prose = UTF16Text("unit tests pass")
        #expect(Pipeline.redactSecondaryAddress(prose, []).isEmpty)
    }

    @Test func tokenizerRejectsTruncatedData() {
        #expect(Tokenizer(bytes: [0x52, 0x44, 0x54, 0x4B]) == nil)
        var header = [UInt8](repeating: 0, count: 21)
        header.replaceSubrange(0...3, with: [0x52, 0x44, 0x54, 0x4B])
        #expect(Tokenizer(bytes: header) == nil)
    }

    @Test func optionsClampInvalidConfidence() {
        #expect(Options(minimumConfidence: -1).minimumConfidence == 0)
        #expect(Options(minimumConfidence: 2).minimumConfidence == 1)
        #expect(Options(minimumConfidence: .nan).minimumConfidence == 0.6)
    }

    // MARK: deterministic parity vs the Python reference (1354 cases)

    // The corpus is a SwiftPM resource, and `Bundle.module` has no WASI backing,
    // so the parity run is off-wasm; the recognizers themselves are exercised
    // above on every platform (on wasm through the JS RegExp backend).
#if !os(WASI)
    @Test func deterministicCorpusParity() throws {
        struct Row: Decodable {
            let text: String
            let py: [Expected]
        }
        struct Expected: Decodable {
            let start: Int, end: Int, label: String
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                start = try c.decode(Int.self)
                end = try c.decode(Int.self)
                label = try c.decode(String.self)
            }
        }
        let enabled: Set<String> = [
            "EMAIL", "URL", "IP_ADDRESS", "CREDIT_CARD", "BANK_ACCOUNT", "GOVERNMENT_ID",
            "TAX_ID", "PASSPORT", "DRIVERS_LICENSE", "IMEI", "SSN", "ROUTING_NUMBER", "PHONE",
        ]
        let url = try #require(Bundle.module.url(forResource: "deterministic_corpus", withExtension: "json"))
        let rows = try JSONDecoder().decode([Row].self, from: try Data(contentsOf: url))
        #expect(rows.count > 1000)
        var failures: [String] = []
        for row in rows {
            let got = Set(Deterministic.detect(row.text, enabled: enabled).map { "\($0.start),\($0.end),\($0.label)" })
            let want = Set(row.py.map { "\($0.start),\($0.end),\($0.label)" })
            if got != want { failures.append("\(row.text): want \(want.sorted()) got \(got.sorted())") }
        }
        // A `Comment` takes a string literal or interpolation, not a built String.
        let sample = failures.prefix(5).joined(separator: "\n")
        #expect(failures.isEmpty, "\(failures.count) mismatches\n\(sample)")
    }
#endif
}

// MARK: model-backed

// `.modelBacked` (TestSupport) decides where these run - one trait on the suite
// rather than a platform `#if` around each test, so they still compile everywhere
// and a skip is reported instead of silently vanishing from the count. wasm is the
// exception that does need the compile-time guard: there the shared fixture does
// not exist, because the model store's filesystem and transport come from the JS
// host the app installs, which the bare test harness never does.
//
// `.serialized` because swift-testing runs tests in parallel by default, and each
// `Redact()` would otherwise load its own Core ML session for the same model.
#if !os(WASI)
@Suite(.serialized, .modelBacked) struct RedactModelTests {
    /// A redactor over the cached model (offline after the fixture's download).
    private func cachedRedact() -> Redact { Redact() }

    @Test func tokenizerLoads() async throws {
        let files = try await ModelFixture.files(RedactModel.self)
        let tok = try #require(Tokenizer(bytes: try files.read(RedactModel.tokenizer)))
        #expect(tok.bosID == 0)
        #expect(tok.eosID == 2)
        #expect(!tok.tokenize("Contact Anna Kovács in Berlin").isEmpty)
    }

    @Test func localModelDirectory() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("redact-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ModelFixture.populate(RedactModel.self, into: directory)

        let redact = Redact(directory: directory.path)
        #expect(redact.isDownloaded())
        #expect(!Redact(directory: directory.path + "-missing").isDownloaded())

        // A directory holding an interrupted download (a `.dal-meta` marker but
        // no verified manifest) is not adopted as a complete model.
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".dal-meta"), withIntermediateDirectories: true)
        #expect(!Redact(directory: directory.path).isDownloaded())
        try FileManager.default.removeItem(at: directory.appendingPathComponent(".dal-meta"))

        // download drives the load to completion and reports final progress.
        let progress = LockedDouble()
        try await redact.download { progress.set($0) }
        #expect(abs(progress.get() - 1.0) < 0.0001)

        // Concurrent redactions share the single load (no crash, both succeed).
        async let a = redact.redaction(of: "Email anna@example.com")
        async let b = redact.redaction(of: "Email bob@example.com")
        let (ra, rb) = try await (a, b)
        #expect(ra.redactedText.contains("[EMAIL_1]"))
        #expect(rb.redactedText.contains("[EMAIL_1]"))
    }

    @Test func redactEndToEnd() async throws {
        let r = try await cachedRedact().redaction(of: "Email Anna Kovács at anna@example.hu.")
        #expect(r.redactedText.contains("[EMAIL_1]"))
        #expect(!r.redactedText.contains("anna@example.hu"))
    }

    /// The neural detector finds the name.
    ///
    /// `.needsNeuralEngine` because the current `redact.mlmodelc` returns no
    /// neural spans whatsoever on Core ML's CPU and GPU paths - not lower
    /// confidence, nothing - while returning them at confidence 1.0 on the Neural
    /// Engine. That is a model-export defect (emo's export agrees across all
    /// units), and it means the SDK silently degrades to deterministic-only
    /// redaction on an Intel Mac, a virtualized Mac, or the simulator. Drop the
    /// trait once redact is re-exported.
    ///
    /// The threshold is explicit and low so this checks that the span is
    /// *detected*, not that it clears the shipping default of 0.6.
    @Test(.needsNeuralEngine) func neuralNameDetection() async throws {
        let r = try await cachedRedact().redaction(
            of: "Email Anna Kovács at anna@example.hu.",
            options: .init(minimumConfidence: 0.1))
        #expect(r.items.contains { $0.label == .givenName && $0.original == "Anna" },
                "no GIVEN_NAME span: \(r.items.map { "\($0.label.rawValue)=\($0.original)" })")
        #expect(!r.redactedText.contains("Anna"))
    }

    @Test func labelFilter() async throws {
        let text = "Call +34 600 100 200 or email me@x.com"
        let phonesOnly = try await cachedRedact().redaction(of: text, options: .init(labels: [.phone]))
        #expect(phonesOnly.items.allSatisfy { $0.label == .phone })
        #expect(phonesOnly.items.contains { $0.original.contains("600") })
        #expect(phonesOnly.redactedText.contains("[PHONE_1]"))     // phone redacted
        #expect(phonesOnly.redactedText.contains("me@x.com"))      // email kept (filtered out)
    }

    @Test func reversibleRoundTrip() async throws {
        let text = "Email anna@example.hu and bob@example.hu about the invoice."
        let r = try await cachedRedact().redaction(of: text)
        #expect(r.items.filter { $0.label == .email }.count == 2)
        #expect(r.redactedText.contains("[EMAIL_1]"))
        #expect(r.redactedText.contains("[EMAIL_2]"))
        #expect(!r.redactedText.contains("example.hu"))
        // An LLM rewrites the text but keeps the placeholders.
        let rewritten = "Please contact [EMAIL_1] (cc [EMAIL_2]) regarding the invoice."
        let restored = r.restore(rewritten)
        #expect(restored.contains("anna@example.hu"))
        #expect(restored.contains("bob@example.hu"))
        #expect(!restored.contains("[EMAIL_"))
    }
}
#endif
