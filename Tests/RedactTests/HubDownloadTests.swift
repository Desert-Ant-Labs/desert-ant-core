#if !os(WASI)
import XCTest
import Foundation
@testable import Redact

/// End-to-end: download the model from the Hub (no bundled resources), then run
/// a real redaction. Network + the real model, so opt-in via HF_INTEGRATION=1.
final class HubDownloadTests: XCTestCase {
    func testDownloadThenRedact() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HF_INTEGRATION"] == "1",
                          "set HF_INTEGRATION=1 to run the network test")
        let tmp = NSTemporaryDirectory() + "redact-hub-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let redact = Redact(directory: tmp)
        XCTAssertFalse(redact.isDownloaded())
        try await redact.download { print("download \(Int($0 * 100))%") }
        XCTAssertTrue(redact.isDownloaded())  // offline check, verified
        let r = try await redact.redaction(of: "Email Anna Kovács at anna@example.com about the invoice.")
        XCTAssertTrue(r.redactedText.contains("[EMAIL_1]"), r.redactedText)
        XCTAssertTrue(r.redactedText.contains("[GIVEN_NAME_1]"), r.redactedText)
        XCTAssertEqual(r.items.first { $0.label.rawValue == "EMAIL" }?.original, "anna@example.com")

        // A second redactor loads from the cache with no network.
        let cached = Redact(directory: tmp)
        let r2 = try await cached.redaction(of: "Card 4111111111111111.")
        XCTAssertTrue(r2.redactedText.contains("[CREDIT_CARD_1]"), r2.redactedText)
    }
}
#endif
