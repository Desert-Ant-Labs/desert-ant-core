#if !os(WASI)
import Testing
import TestSupport
@testable import Moderator

@Suite(.hubIntegration)
struct HubDownloadTests {
    @Test func downloadThenAnalyze() async throws {
        try await HubDownloadScenario.run(
            ModeratorModel.self,
            make: { Moderator(directory: $0) },
            isDownloaded: { $0.isDownloaded() },
            download: { try await $0.download(progress: $1) }
        ) { moderator, cached in
            let golden = try Golden.load()
            let image = ModeratorTests.synthetic(width: golden.synthetic.width, height: golden.synthetic.height)
            let result = try await moderator.analyze(image, options: .init(quality: .fast))
            #expect(abs(result.regions.nude - golden.synthetic.fast.nude) < 0.02)

            // The second moderator reads the same directory with no network.
            let offline = try await cached.analyze(image, options: .init(quality: .fast))
            #expect(offline == result)
        }
    }
}
#endif
