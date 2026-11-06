#if !os(WASI)
import Testing
import TestSupport
@testable import Toxic

@Suite(.hubIntegration)
struct HubDownloadTests {
    @Test func downloadThenAnalyze() async throws {
        try await HubDownloadScenario.run(
            ToxicModel.self,
            make: { Toxic(directory: $0) },
            isDownloaded: { $0.isDownloaded() },
            download: { try await $0.download(progress: $1) }
        ) { toxic, cached in
            let golden = try Golden.load()
            let result = try await toxic.analyze(golden.texts[4])
            #expect(result.flagged.contains(.hateful))

            // The second classifier reads the same directory with no network.
            let offline = try await cached.analyze(golden.texts[4])
            #expect(offline == result)
        }
    }
}
#endif
