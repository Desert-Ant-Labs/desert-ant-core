// Availability is the manifest plus one stat per file, and nothing else. These
// pin both halves of that: what the check accepts and rejects, and - through a
// filesystem that counts the calls - that deciding it reads no model file. The
// cryptographic check still exists, behind `verify`.
#if !os(WASI)
import Testing
import Foundation
@testable import ModelStore

/// Forwards to a real filesystem, counting the two calls that read contents.
/// Reading the manifest is expected; hashing a model file is the whole cost
/// this check exists to avoid, so `digestCount` is the assertion that matters.
final class CountingFileSystem: FileSystem, @unchecked Sendable {
    private let inner: FileSystem
    private let lock = NSLock()
    private var digests = 0
    private var reads = 0

    var digestCount: Int { lock.withLock { digests } }
    var readCount: Int { lock.withLock { reads } }

    init(_ inner: FileSystem) { self.inner = inner }
    func reset() { lock.withLock { digests = 0; reads = 0 } }

    func digest(_ path: String) throws -> (size: Int64, sha256: String) {
        lock.withLock { digests += 1 }
        return try inner.digest(path)
    }
    func read(_ path: String) throws -> [UInt8] {
        lock.withLock { reads += 1 }
        return try inner.read(path)
    }
    func exists(_ path: String) -> Bool { inner.exists(path) }
    func size(_ path: String) -> Int64? { inner.size(path) }
    func write(_ path: String, _ bytes: [UInt8]) throws { try inner.write(path, bytes) }
    func makeDirectory(_ path: String) throws { try inner.makeDirectory(path) }
    func move(_ from: String, to: String) throws { try inner.move(from, to: to) }
    func remove(_ path: String) { inner.remove(path) }
    func defaultCacheRoot() -> String { inner.defaultCacheRoot() }
    func listDirectory(_ path: String) -> [String] { inner.listDirectory(path) }
}

final class AvailabilityTests {
    private let tmp: String
    /// Folder-shaped, with one large-ish weight file: the model shape whose
    /// hashing is what made a warm launch slow.
    private let payload: [String: [UInt8]] = [
        "model.mlmodelc/model.mil": [UInt8](repeating: 0x11, count: 4096),
        "model.mlmodelc/weights/weight.bin": [UInt8](repeating: 0x22, count: 1 << 16),
        "meta.json": Array("{}".utf8),
    ]
    private let weights = "model.mlmodelc/weights/weight.bin"

    init() { tmp = NSTemporaryDirectory() + "dal-availability-\(UUID().uuidString)" }
    deinit { try? FileManager.default.removeItem(atPath: tmp) }

    /// A downloaded model, with the counter zeroed at the end of the download
    /// so what it reports afterwards is the availability check's own work.
    private func warmCache() async throws -> (ModelStore, CountingFileSystem, ModelSpec) {
        let fs = CountingFileSystem(FoundationFileSystem())
        let store = ModelStore(transport: MockTransport(payload), fileSystem: fs,
                               endpoint: "https://hub.test")
        let m = ModelSpec(repo: "desert-ant-labs/voz", revision: "v0.1.0",
                          files: payload.keys.sorted(), cacheDirectory: tmp)
        try await store.download(m)
        fs.reset()
        return (store, fs, m)
    }

    private func path(_ store: ModelStore, _ m: ModelSpec, _ file: String) -> String {
        store.location(of: m) + "/" + file
    }
    private func write(_ bytes: [UInt8], to path: String) throws {
        try Data(bytes).write(to: URL(fileURLWithPath: path))
    }

    /// Check, then download, then check again: what every SDK initializer runs,
    /// and what used to pay a full hash of the model three times over.
    @Test func theWarmPathNeverHashes() async throws {
        let (store, fs, m) = try await warmCache()
        #expect(store.isDownloaded(m))
        #expect(fs.digestCount == 0, "the availability check hashed \(fs.digestCount) file(s)")
        #expect(fs.readCount == 1, "it read \(fs.readCount) files, not the manifest alone")

        try await store.download(m)   // cached: no network, no work
        #expect(store.isDownloaded(m))
        #expect(fs.digestCount == 0, "the cached download path hashed \(fs.digestCount) file(s)")
    }

    @Test func aMissingFileIsNotAvailable() async throws {
        let (store, fs, m) = try await warmCache()
        try FileManager.default.removeItem(atPath: path(store, m, "meta.json"))
        #expect(!store.isDownloaded(m))
        #expect(fs.digestCount == 0, "an absent file is a stat, not a hash")
    }

    @Test func aFileThatIsNoLongerItsRecordedSizeIsNotAvailable() async throws {
        let (short, _, a) = try await warmCache()
        try write([UInt8](repeating: 0x22, count: (1 << 16) - 1), to: path(short, a, weights))
        #expect(!short.isDownloaded(a), "a truncated file passed as available")

        let (grown, _, b) = try await warmCache()
        try write([UInt8](repeating: 0x22, count: (1 << 16) + 1), to: path(grown, b, weights))
        #expect(!grown.isDownloaded(b), "an overlong file passed as available")
    }

    @Test func unrelatedFilesInTheDirectoryDoNotMatter() async throws {
        let (store, _, m) = try await warmCache()
        try write(Array("scratch".utf8), to: path(store, m, "notes.txt"))
        try FileManager.default.createDirectory(atPath: path(store, m, "stale.mlmodelc"),
                                                withIntermediateDirectories: true)
        #expect(store.isDownloaded(m), "availability is the manifest's entries, not the directory's")
    }

    @Test func neitherCheckPassesWithoutTheManifest() async throws {
        let (store, _, m) = try await warmCache()
        try FileManager.default.removeItem(
            atPath: path(store, m, ModelStore.metadataDirectory + "/manifest"))
        #expect(!store.isDownloaded(m))
        #expect(!store.verify(m))
    }

    /// The distinction the split is for: same length, different bytes. The one
    /// case availability cannot see and verify can.
    @Test func verifyHashesEveryEntryAndCatchesCorruptionThatKeptItsLength() async throws {
        let (store, fs, m) = try await warmCache()
        #expect(store.verify(m))
        #expect(fs.digestCount == payload.count, "verify must hash every manifest entry")

        try write([UInt8](repeating: 0xFF, count: 1 << 16), to: path(store, m, weights))
        #expect(store.isDownloaded(m))
        #expect(!store.verify(m))
    }
}
#endif
