#if !os(WASI)
import Testing
import Foundation
@testable import ModelStore

/// `isInstalled` (behind every SDK's `isDownloaded()`) answers by size, not by hashing.
@Suite struct InstalledCheckTests {
    private let tmp = NSTemporaryDirectory() + "dal-installed-\(UUID().uuidString)"
    private let payload = ["model.bin": [UInt8](repeating: 3, count: 4096)]

    private func distribution() -> ModelDistribution {
        ModelDistribution(repo: "desert-ant-labs/example", revision: "v1",
                          files: [.current: ["model.bin"]])
    }

    private func install() async throws {
        let d = distribution()
        let store = ModelStore(transport: MockTransport(payload), fileSystem: FoundationFileSystem(),
                               endpoint: "https://hub.test")
        try await store.download(ModelSpec(repo: d.repo, revision: d.revision,
                                           files: try #require(d.currentFiles), cacheDirectory: tmp))
    }

    @Test func installedModelIsReported() async throws {
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        #expect(!distribution().isInstalled(cacheDirectory: tmp))
        try await install()
        #expect(distribution().isInstalled(cacheDirectory: tmp))
    }

    @Test func truncatedFileIsNotInstalled() async throws {
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try await install()
        try Data([1]).write(to: URL(fileURLWithPath: tmp + "/model.bin"))
        #expect(!distribution().isInstalled(cacheDirectory: tmp))
    }

    @Test func sameSizeCorruptionIsLeftForFullVerification() async throws {
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        try await install()
        try Data([UInt8](repeating: 0, count: 4096)).write(to: URL(fileURLWithPath: tmp + "/model.bin"))
        #expect(distribution().isInstalled(cacheDirectory: tmp), "isInstalled is documented as size-only")
    }
}
#endif
