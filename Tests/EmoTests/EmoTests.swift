import Foundation
import XCTest
import DesertAnt
import TestSupport
@testable import Emo

/// End-to-end suggestion through the downloaded model. On Apple this runs the
/// Core ML artifact; on Linux/Windows the LiteRT artifact (via LiteRT). Both
/// exports come from the same checkpoint and share one fixed-window signature, so
/// the results match.
final class EmoTests: XCTestCase {
    // The model-backed tests are wasm-guarded because the shared fixture does not
    // exist there (the model store's filesystem and transport come from the JS host
    // the app installs, which the bare test harness never does), and skipped off
    // iOS/Android by `requireModelBacked` - the XCTest equivalent of swift-testing's
    // `.modelBacked` trait that RedactTests applies to its whole suite.
#if !os(WASI)
    /// Skip unless this is a platform where model-backed tests run.
    private func requireModelBacked() throws {
        try XCTSkipUnless(runsModelBackedTests, "model-backed tests do not run on iOS or Android")
    }

    /// A suggester over the cached model (offline after the fixture's download).
    private func makeEmo() -> Emo { Emo() }

    private func top(_ text: String) async throws -> String {
        try await makeEmo().suggestions(for: text, limit: 1).first?.emoji ?? ""
    }

    func testEnglishPredictions() async throws {
        try requireModelBacked()
        let emo = makeEmo()
        let bills = try await emo.suggestions(for: "Pay my bills", limit: 5).map(\.emoji)
        XCTAssertTrue(bills.contains { ["💰", "💳", "🧾", "🏦", "📄"].contains($0) }, "got \(bills)")
        let dog = try await emo.suggestions(for: "walk the dog", limit: 5).map(\.emoji)
        XCTAssertTrue(dog.contains { ["🐕", "🐾", "🚶"].contains($0) }, "got \(dog)")
        let flight = try await emo.suggestions(for: "book a flight to Tokyo", limit: 5).map(\.emoji)
        XCTAssertTrue(flight.contains("✈️"), "got \(flight)")
    }

    func testMultilingualPredictions() async throws {
        try requireModelBacked()
        let emo = makeEmo()
        let walk = try await emo.suggestions(for: "犬の散歩", limit: 5).map(\.emoji)
        XCTAssertTrue(walk.contains { ["🐕", "🐾"].contains($0) }, "got \(walk)")
        let coffee = try await emo.suggestions(for: "café con leche", limit: 5).map(\.emoji)
        XCTAssertTrue(coffee.contains { ["☕", "🍵", "🥛"].contains($0) }, "got \(coffee)")
    }

    func testRanking() async throws {
        try requireModelBacked()
        let results = try await makeEmo().suggestions(for: "Pay my bills", limit: 3)
        XCTAssertEqual(results.count, 3)
        XCTAssertGreaterThanOrEqual(results[0].confidence, results[1].confidence)
        XCTAssertTrue(results.allSatisfy { (0...1).contains($0.confidence) })
    }

    func testEmptyInput() async throws {
        try requireModelBacked()
        let results = try await makeEmo().suggestions(for: "   ")
        XCTAssertTrue(results.isEmpty)
    }

    /// A model directory the user populated is adopted offline, with no download.
    func testPrepopulatedDirectoryIsAdopted() async throws {
        try requireModelBacked()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("emo-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ModelFixture.populate(EmoModel.self, into: directory)

        let emo = Emo(directory: directory.path)
        XCTAssertTrue(emo.isDownloaded())
        let results = try await emo.suggestions(for: "Pay my bills", limit: 3)
        XCTAssertEqual(results.count, 3)
    }

#endif

    func testSkinTonePostprocessing() {
        XCTAssertEqual("🏃".applyingSkinTone(.medium), "🏃🏽")
        XCTAssertEqual("🧑‍🍳".applyingSkinTone(.dark), "🧑🏿‍🍳")
        XCTAssertEqual("✍️".applyingSkinTone(.light), "✍🏻")
        XCTAssertEqual("🐕".applyingSkinTone(.medium), "🐕")
    }
}
