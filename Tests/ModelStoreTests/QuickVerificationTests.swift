#if !os(WASI)
import Testing
import Foundation
@testable import ModelStore

/// `.quick` trades content hashing for a size check: it must catch what a size
/// can show, and must not read file content to do it.
@Suite struct QuickVerificationTests {
    private let tmp = NSTemporaryDirectory() + "dal-quick-\(UUID().uuidString)"
    private let payload = ["a.bin": [UInt8](repeating: 0x41, count: 4096),
                           "sub/b.bin": [UInt8](repeating: 0x42, count: 300)]

    private func downloaded() async throws -> (ModelStore, ModelSpec) {
        let store = ModelStore(transport: MockTransport(payload), fileSystem: FoundationFileSystem(),
                               endpoint: "https://hub.test")
        let spec = ModelSpec(repo: "desert-ant-labs/redact", revision: "v1",
                             files: ["a.bin", "sub/b.bin"], cacheDirectory: tmp)
        try await store.download(spec)
        return (store, spec)
    }

    @Test func intactModelPassesBothLevels() async throws {
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (store, spec) = try await downloaded()
        #expect(store.isDownloaded(spec, verification: .quick))
        #expect(store.isDownloaded(spec, verification: .full))
        #expect(store.isDownloaded(spec) == store.isDownloaded(spec, verification: .full))
    }

    @Test func missingManifestFailsQuick() async throws {
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (store, spec) = try await downloaded()
        try FileManager.default.removeItem(atPath: tmp + "/.dal-meta/manifest")
        #expect(!store.isDownloaded(spec, verification: .quick))
    }

    @Test func missingOrTruncatedFileFailsQuick() async throws {
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (store, spec) = try await downloaded()

        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: tmp + "/sub/b.bin"))
        #expect(!store.isDownloaded(spec, verification: .quick), "truncated file went unnoticed")

        try FileManager.default.removeItem(atPath: tmp + "/a.bin")
        #expect(!store.isDownloaded(spec, verification: .quick), "missing file went unnoticed")
    }

    @Test func quickDoesNotReadContentSoSameSizeCorruptionNeedsFull() async throws {
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (store, spec) = try await downloaded()
        // Same size, different bytes: the documented blind spot of `.quick`.
        try Data([UInt8](repeating: 0x00, count: 4096)).write(to: URL(fileURLWithPath: tmp + "/a.bin"))
        #expect(store.isDownloaded(spec, verification: .quick))
        #expect(!store.isDownloaded(spec, verification: .full))
    }

    @Test func manifestForOtherRequestedFilesFailsQuick() async throws {
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (store, _) = try await downloaded()
        let other = ModelSpec(repo: "desert-ant-labs/redact", revision: "v1",
                              files: ["a.bin"], cacheDirectory: tmp)
        #expect(!store.isDownloaded(other, verification: .quick))
    }
}
#endif
