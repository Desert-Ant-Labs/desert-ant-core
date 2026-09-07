#if !os(WASI)
import Testing
import TestSupport
@testable import Emo

@Suite(.hubIntegration)
struct HubDownloadTests {
    @Test func downloadThenSuggest() async throws {
        try await HubDownloadScenario.run(
            EmoModel.self,
            make: { Emo(directory: $0) },
            isDownloaded: { $0.isDownloaded() },
            download: { try await $0.download(progress: $1) }
        ) { emo, cached in
            let suggestions = try await emo.suggestions(for: "Pay my bills", limit: 3)
            #expect(suggestions.count == 3)

            let flight = try await cached
                .suggestions(for: "book a flight to Tokyo", limit: 5)
                .map(\.emoji)
            #expect(flight.contains("✈️"), "got \(flight)")
        }
    }
}
#endif
