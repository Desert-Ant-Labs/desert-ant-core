import Foundation
import Testing
import DesertAnt
import TestSupport
@testable import Emo

// The model-backed tests are wasm-guarded because the shared fixture does not
// exist there (the model store's filesystem and transport come from the JS host
// the app installs, which the bare test harness never does), and skipped off
// iOS/Android by the `.modelBacked` trait. `.serialized` keeps the instances
// from resolving the same model concurrently, the house pattern for model
// suites (see Ear's SmokeTests).
#if !os(WASI)
/// End-to-end suggestion through the downloaded model. On Apple this runs the
/// Core ML artifact; on Linux/Windows the LiteRT artifact (via LiteRT). Both
/// exports come from the same checkpoint and share one fixed-window signature, so
/// the results match.
@Suite(.serialized, .modelBacked)
struct EmoModelTests {
    /// A suggester over the cached model (offline after the fixture's download).
    private func makeEmo() -> Emo { Emo() }

    @Test func englishPredictions() async throws {
        let emo = makeEmo()
        let bills = try await emo.suggestions(for: "Pay my bills", limit: 5).map(\.emoji)
        #expect(bills.contains { ["💰", "💳", "🧾", "🏦", "📄"].contains($0) }, "got \(bills)")
        let dog = try await emo.suggestions(for: "walk the dog", limit: 5).map(\.emoji)
        #expect(dog.contains { ["🐕", "🐾", "🚶"].contains($0) }, "got \(dog)")
        let flight = try await emo.suggestions(for: "book a flight to Tokyo", limit: 5).map(\.emoji)
        #expect(flight.contains("✈️"), "got \(flight)")
    }

    @Test func multilingualPredictions() async throws {
        let emo = makeEmo()
        let walk = try await emo.suggestions(for: "犬の散歩", limit: 5).map(\.emoji)
        #expect(walk.contains { ["🐕", "🐾"].contains($0) }, "got \(walk)")
        let coffee = try await emo.suggestions(for: "café con leche", limit: 5).map(\.emoji)
        #expect(coffee.contains { ["☕", "🍵", "🥛"].contains($0) }, "got \(coffee)")
    }

    @Test func ranking() async throws {
        let results = try await makeEmo().suggestions(for: "Pay my bills", limit: 3)
        #expect(results.count == 3)
        #expect(results[0].confidence >= results[1].confidence)
        #expect(results.allSatisfy { (0...1).contains($0.confidence) })
    }

    @Test func emptyInput() async throws {
        let results = try await makeEmo().suggestions(for: "   ")
        #expect(results.isEmpty)
    }

    /// A model directory the user populated is adopted offline, with no download.
    @Test func prepopulatedDirectoryIsAdopted() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("emo-local-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await ModelFixture.populate(EmoModel.self, into: directory)

        let emo = Emo(directory: directory.path)
        #expect(emo.isDownloaded())
        let results = try await emo.suggestions(for: "Pay my bills", limit: 3)
        #expect(results.count == 3)
    }

    /// The vocab is keyed on a piece's UTF-8 bytes, not on `String`.
    ///
    /// Swift's `String` equality is Unicode canonical equivalence, so a
    /// `[String: Int32]` vocab merges byte-distinct pieces that normalize alike,
    /// and the later id evicts the earlier. This vocab has exactly two such
    /// pairs, both common Vietnamese words, and in both the decomposed entry
    /// holds the higher id - so it took the key and the composed entry, the only
    /// form NFKC can ever produce, became unreachable. Both words then encoded to
    /// an id the training tokenizer never assigns them.
    @Test func vietnameseVocabPiecesAreReachable() async throws {
        let files = try await ModelFixture.files(EmoModel.self)
        let sem = try #require(SemTokenizer(bytes: try files.read(EmoModel.tokenizer)))
        // emo v0.7.0: `▁một` is 688 composed / 39184 decomposed, and `▁ở` is
        // 1493 / 41329. A re-cut vocab moves these, and should fail here loudly.
        #expect(sem.encode("một") == [688])
        #expect(sem.encode("ở") == [1493])
        // Whichever form the caller types, NFKC composes it to the same piece.
        #expect(sem.encode("m\u{006F}\u{0323}\u{0302}t") == sem.encode("m\u{1ED9}t"))
    }
}
#endif

struct EmoTests {
    @Test func skinTonePostprocessing() {
        #expect("🏃".applyingSkinTone(.medium) == "🏃🏽")
        #expect("🧑‍🍳".applyingSkinTone(.dark) == "🧑🏿‍🍳")
        #expect("✍️".applyingSkinTone(.light) == "✍🏻")
        #expect("🐕".applyingSkinTone(.medium) == "🐕")
    }
}
