#if !os(WASI)
import XCTest
import TestSupport
@testable import Clear

final class HubDownloadTests: XCTestCase {
    func testDownloadThenEnhance() async throws {
        try await HubDownloadScenario.run(
            ClearModel.self,
            make: { Clear(directory: $0) },
            isDownloaded: { $0.isDownloaded() },
            download: { try await $0.download(progress: $1) }
        ) { clear, cached in
            // A second of tone plus noise: enough frames for several model
            // chunks, cheap enough for a network-gated test.
            let noisy = noisyTone()
            let result = try await clear.enhance(samples: noisy, sampleRate: 48_000)
            XCTAssertEqual(result.sampleRate, 48_000)
            XCTAssertTrue(result.samples.allSatisfy { $0.isFinite })
            XCTAssertNotNil(result.measuredLUFS)
            // Downloaded through the store, so the artifact names its variant.
            XCTAssertEqual(result.modelVariant, .clearStudio)

            // The cached instance loads the same files with no network.
            let again = try await cached.enhance(samples: noisy, sampleRate: 48_000,
                                                 options: .init(mastering: .bypass))
            XCTAssertEqual(again.samples.count, result.samples.count)
            XCTAssertNil(again.measuredLUFS)   // mastering bypassed
        }
    }
}
#endif
