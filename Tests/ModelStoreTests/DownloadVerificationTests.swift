#if !os(WASI)
import Testing
import Foundation
@testable import ModelStore

/// Counts content reads, so a test can prove a path never hashed the model.
final class CountingFileSystem: FileSystem, @unchecked Sendable {
    private let inner = FoundationFileSystem()
    private let lock = NSLock()
    private var digests = 0
    private var reads: [String] = []
    var digestCount: Int { lock.withLock { digests } }
    /// Paths handed to `read`, i.e. files pulled into memory whole.
    var readPaths: [String] { lock.withLock { reads } }

    func exists(_ path: String) -> Bool { inner.exists(path) }
    func size(_ path: String) -> Int64? { inner.size(path) }
    func read(_ path: String) throws -> [UInt8] {
        lock.withLock { reads.append(path) }
        return try inner.read(path)
    }
    func write(_ path: String, _ bytes: [UInt8]) throws { try inner.write(path, bytes) }
    func makeDirectory(_ path: String) throws { try inner.makeDirectory(path) }
    func move(_ from: String, to: String) throws { try inner.move(from, to: to) }
    func remove(_ path: String) { inner.remove(path) }
    func defaultCacheRoot() -> String { inner.defaultCacheRoot() }
    func listDirectory(_ path: String) -> [String] { inner.listDirectory(path) }
    func digest(_ path: String) throws -> (size: Int64, sha256: String) {
        lock.withLock { digests += 1 }
        return try inner.digest(path)
    }
}

/// How hard `download` looks before it decides a model is already there.
@Suite struct DownloadVerificationTests {
    private let tmp = NSTemporaryDirectory() + "dal-dlverify-\(UUID().uuidString)"
    private let good = [UInt8](repeating: 0x9, count: 4096)

    private func spec() -> ModelSpec {
        ModelSpec(repo: "desert-ant-labs/redact", revision: "v1", files: ["m.bin"], cacheDirectory: tmp)
    }

    @Test func quickShortCircuitNeverHashesOrTouchesTheNetwork() async throws {
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let fs = CountingFileSystem()
        let first = ModelStore(transport: MockTransport(["m.bin": good]), fileSystem: fs, endpoint: "https://hub.test")
        try await first.download(spec())
        let hashedByDownload = fs.digestCount

        let offline = ModelStore(transport: OfflineTransport(), fileSystem: fs, endpoint: "https://hub.test")
        try await offline.download(spec(), verification: .quick)
        #expect(fs.digestCount == hashedByDownload, "quick verification re-hashed the model")
    }

    @Test func quickRefetchesATruncatedFile() async throws {
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let t = MockTransport(["m.bin": good])
        let s = ModelStore(transport: t, fileSystem: FoundationFileSystem(), endpoint: "https://hub.test")
        try await s.download(spec())
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: tmp + "/m.bin"))

        try await s.download(spec(), verification: .quick)
        #expect(t.downloadCount == 2)
        #expect(s.isDownloaded(spec(), verification: .full))
    }

    @Test func quickLeavesSameSizeCorruptionAndFullRepairsIt() async throws {
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let t = MockTransport(["m.bin": good])
        let s = ModelStore(transport: t, fileSystem: FoundationFileSystem(), endpoint: "https://hub.test")
        try await s.download(spec())
        try Data([UInt8](repeating: 0xFF, count: good.count)).write(to: URL(fileURLWithPath: tmp + "/m.bin"))

        try await s.download(spec(), verification: .quick)
        #expect(t.downloadCount == 1, "quick is documented to trust a same-size file")

        try await s.download(spec())  // default is .full
        #expect(t.downloadCount == 2)
        #expect(s.isDownloaded(spec(), verification: .full))
    }

    @Test func fetchHashesTheDownloadWithoutReadingItWhole() async throws {
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let fs = CountingFileSystem()
        let s = ModelStore(transport: MockTransport(["m.bin": good]), fileSystem: fs, endpoint: "https://hub.test")
        try await s.download(spec())
        #expect(!fs.readPaths.contains { $0.hasSuffix("m.bin") || $0.hasSuffix("m.bin.part") },
                "a model file was read into memory whole: \(fs.readPaths)")
        #expect(s.isDownloaded(spec(), verification: .full))
    }

    @Test func resumeSkipsAVerifiedFileWithoutReadingItWhole() async throws {
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let fs = CountingFileSystem()
        let t = MockTransport(["m.bin": good])
        let s = ModelStore(transport: t, fileSystem: fs, endpoint: "https://hub.test")
        try await s.download(spec())
        // A prior run that finished the file but not the manifest.
        try FileManager.default.removeItem(atPath: tmp + "/.dal-meta/manifest")

        try await s.download(spec())
        #expect(t.downloadCount == 1, "an intact LFS file was downloaded again")
        #expect(!fs.readPaths.contains { $0.hasSuffix("m.bin") }, "resume read the file whole")
        #expect(s.isDownloaded(spec(), verification: .full))
    }

    @Test func aWrongSizeDownloadStillFailsIntegrity() async throws {
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let s = ModelStore(transport: MockTransport(["m.bin": good], sizeOverride: 5000),
                           fileSystem: FoundationFileSystem(), endpoint: "https://hub.test")
        await #expect(throws: ModelStoreError.self) { try await s.download(spec()) }
        #expect(!FileManager.default.fileExists(atPath: tmp + "/m.bin"))
    }
}
#endif
