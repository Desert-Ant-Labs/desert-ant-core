#if !os(WASI)
import Foundation
import XCTest
@testable import Emo

/// End-to-end: download the model from the Hub (no bundled resources), then run
/// a real suggestion. Network + the real model, so opt-in via HF_INTEGRATION=1.
/// The non-Apple path needs `emo.tflite` published on the model repo at the
/// pinned revision (Apple uses `emo.mlmodelc`).
final class HubDownloadTests: XCTestCase {
    func testDownloadThenSuggest() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HF_INTEGRATION"] == "1",
                          "set HF_INTEGRATION=1 to run the network test")
        let tmp = NSTemporaryDirectory() + "emo-hub-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let emo = Emo(directory: tmp)
        XCTAssertFalse(emo.isDownloaded())
        try await emo.download { print("download \(Int($0 * 100))%") }
        XCTAssertTrue(emo.isDownloaded())

        let suggestions = try await emo.suggestions(for: "Pay my bills", limit: 3)
        XCTAssertEqual(suggestions.count, 3)

        // A second suggester loads from the cache with no network.
        let cached = Emo(directory: tmp)
        XCTAssertTrue(cached.isDownloaded())
        let flight = try await cached.suggestions(for: "book a flight to Tokyo", limit: 5).map(\.emoji)
        XCTAssertTrue(flight.contains("✈️"), "got \(flight)")
    }
}
#endif
