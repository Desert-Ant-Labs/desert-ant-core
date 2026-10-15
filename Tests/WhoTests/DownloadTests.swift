import Foundation
import Testing

@testable import Who

/// Progress callbacks arrive off the calling thread.
final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    var highest: Double { lock.withLock { value } }
    func observe(_ fraction: Double) { lock.withLock { value = max(value, fraction) } }
}

/// `Who()` with nothing on disk: resolution, the download and the cache. Off by default; while the
/// weights repo is private it needs a token and `DAL_HF_REPO_SUFFIX=-private`:
///
///     WHO_TEST_DOWNLOAD=1 swift test --filter WhoTests.DownloadTests
@Suite(.enabled(if: WhoFixtures.downloadEnabled, "reaches the network: set WHO_TEST_DOWNLOAD=1"))
struct DownloadTests {
    static func scratch() -> String {
        let path = NSTemporaryDirectory() + "who-download-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test func downloadsTheDefaultVariantAndThenDiarizes() async throws {
        let cache = Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: cache) }
        let who = Who(directory: nil, cacheRoot: cache)
        #expect(!who.isDownloaded())
        let reported = Reported()
        try await who.download { reported.observe($0) }
        #expect(who.isDownloaded())
        #expect(reported.highest >= 0.99)
        let result = try await who.diarize(samples: SmokeTests.audio(seconds: 40), sampleRate: 16000)
        #expect(abs(result.duration - 40) < 1e-6)
    }

    @Test func theOtherVariantIsItsOwnDownload() async throws {
        let cache = Self.scratch()
        defer { try? FileManager.default.removeItem(atPath: cache) }
        let int8 = Who(directory: nil, cacheRoot: cache, variant: .int8)
        try await int8.download()
        #expect(int8.isDownloaded())
        #expect(!Who(directory: nil, cacheRoot: cache, variant: .fp16).isDownloaded())
    }
}
