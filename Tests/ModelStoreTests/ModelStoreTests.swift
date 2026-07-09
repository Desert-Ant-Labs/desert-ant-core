import XCTest
import Checksum
@testable import ModelStore

/// In-memory transport that serves fixed bytes and reports the SHA-256 as the
/// etag (like a Hugging Face LFS file). `sizeOverride` and `etagOverride` let
/// tests simulate a corrupt/mismatched download.
final class MockTransport: ModelTransport, @unchecked Sendable {
    let files: [String: [UInt8]]
    let sizeOverride: Int64?
    let etagOverride: String?
    private let lock = NSLock()
    private(set) var headCount = 0
    private(set) var downloadCount = 0

    init(_ files: [String: [UInt8]], sizeOverride: Int64? = nil, etagOverride: String? = nil) {
        self.files = files; self.sizeOverride = sizeOverride; self.etagOverride = etagOverride
    }

    func head(_ url: String) async throws -> RemoteFileInfo {
        lock.withLock { headCount += 1 }
        guard let b = files[url] else { throw ModelStoreError.io("404 \(url)") }
        return RemoteFileInfo(etag: etagOverride ?? SHA256.hexDigest(b), commit: "deadbeef",
                              size: sizeOverride ?? Int64(b.count))
    }

    func download(_ url: String, to destinationPath: String, onBytes: @Sendable (Int64) -> Void) async throws {
        lock.withLock { downloadCount += 1 }
        guard let b = files[url] else { throw ModelStoreError.io("404 \(url)") }
        try FoundationFileSystem().write(destinationPath, b)
        onBytes(Int64(b.count))
    }
}

/// Transport that throws on any call: proves the offline path never touches the network.
struct OfflineTransport: ModelTransport {
    func head(_ url: String) async throws -> RemoteFileInfo { throw ModelStoreError.io("offline") }
    func download(_ url: String, to path: String, onBytes: @Sendable (Int64) -> Void) async throws { throw ModelStoreError.io("offline") }
}

final class LockedDouble: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0.0
    func set(_ v: Double) { lock.withLock { value = v } }
    func get() -> Double { lock.withLock { value } }
}

final class ModelStoreTests: XCTestCase {
    private var tmp: String!
    private let endpoint = "https://hub.test"

    override func setUp() {
        tmp = NSTemporaryDirectory() + "dal-modelstore-\(UUID().uuidString)"
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
    }

    private func model(_ files: [String]) -> Model {
        Model(repo: "desert-ant-labs/redact", revision: "v0.2.1", files: files, cacheDirectory: tmp)
    }
    private func url(_ file: String) -> String { "\(endpoint)/desert-ant-labs/redact/resolve/v0.2.1/\(file)" }

    func testDownloadVerifyAndOfflineReuse() async throws {
        let onnx = [UInt8](repeating: 0x41, count: 5000)
        let labels = Array("{\"labels\":[]}".utf8)
        let files = ["redact.onnx", "redact.mlmodelc/weights/weight.bin", "labels.json"]
        let weight = [UInt8](repeating: 0x7, count: 800)
        let payload = [url("redact.onnx"): onnx, url("redact.mlmodelc/weights/weight.bin"): weight, url("labels.json"): labels]

        let store = ModelStore(transport: MockTransport(payload), fileSystem: FoundationFileSystem(), endpoint: endpoint)
        let m = model(files)

        XCTAssertFalse(store.isDownloaded(m))
        let lastFraction = LockedDouble()
        try await store.download(m) { p in lastFraction.set(p.fraction) }
        XCTAssertEqual(lastFraction.get(), 1.0, accuracy: 0.0001)

        // Files present at the right relative paths (nested dir reconstructed).
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.location(of: m) + "/redact.mlmodelc/weights/weight.bin"))
        XCTAssertTrue(store.isDownloaded(m))  // present + hashes match

        // Offline: already downloaded => isDownloaded true and download() a no-op,
        // with a transport that would throw if touched.
        let offline = ModelStore(transport: OfflineTransport(), fileSystem: FoundationFileSystem(), endpoint: endpoint)
        XCTAssertTrue(offline.isDownloaded(m))
        try await offline.download(m)  // must not throw / must not hit network
    }

    func testCorruptionIsDetectedAndReDownloaded() async throws {
        let good = [UInt8](repeating: 0x9, count: 4096)
        let t = MockTransport([url("redact.onnx"): good])
        let store = ModelStore(transport: t, fileSystem: FoundationFileSystem(), endpoint: endpoint)
        let m = model(["redact.onnx"])
        try await store.download(m)
        XCTAssertTrue(store.isDownloaded(m))

        // Corrupt the cached file on disk: isDownloaded always re-hashes, so it
        // now reports false, and download() repairs it.
        try FoundationFileSystem().write(store.location(of: m) + "/redact.onnx", [UInt8](repeating: 0xFF, count: 4096))
        XCTAssertFalse(store.isDownloaded(m))
        try await store.download(m)
        XCTAssertEqual(t.downloadCount, 2)     // the corrupt file was re-fetched
        XCTAssertTrue(store.isDownloaded(m))
    }

    func testSizeMismatchIsRejected() async throws {
        let onnx = [UInt8](repeating: 0x3, count: 2048)
        // Server claims a larger size than the bytes we get.
        let t = MockTransport([url("redact.onnx"): onnx], sizeOverride: 9999)
        let store = ModelStore(transport: t, fileSystem: FoundationFileSystem(), endpoint: endpoint)
        let m = model(["redact.onnx"])
        do {
            try await store.download(m)
            XCTFail("expected integrity failure")
        } catch let e as ModelStoreError {
            if case .integrityCheckFailed = e {} else { XCTFail("wrong error: \(e)") }
        }
        // The bad bytes never became a usable cached file.
        XCTAssertFalse(store.isDownloaded(m))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.location(of: m) + "/redact.onnx"))
    }

    func testHashMismatchIsRejected() async throws {
        let onnx = [UInt8](repeating: 0x3, count: 2048)
        // Server advertises a (valid-shaped) SHA-256 that does not match the bytes.
        let wrong = String(repeating: "a", count: 64)
        let t = MockTransport([url("redact.onnx"): onnx], etagOverride: wrong)
        let store = ModelStore(transport: t, fileSystem: FoundationFileSystem(), endpoint: endpoint)
        let m = model(["redact.onnx"])
        do {
            try await store.download(m)
            XCTFail("expected integrity failure")
        } catch let e as ModelStoreError {
            if case .integrityCheckFailed = e {} else { XCTFail("wrong error: \(e)") }
        }
        XCTAssertFalse(store.isDownloaded(m))
    }

    func testPOSIXFileSystemBackend() async throws {
        // The Android FS backend is raw POSIX and identical on Linux, so run the
        // full download/verify/offline flow through it here.
        let onnx = [UInt8](repeating: 0x2b, count: 6000)
        let weight = [UInt8](repeating: 0x11, count: 1234)
        let files = ["redact.onnx", "redact.mlmodelc/weights/weight.bin"]
        let payload = [url("redact.onnx"): onnx, url("redact.mlmodelc/weights/weight.bin"): weight]
        let posix = POSIXFileSystem(cacheRoot: tmp)
        let store = ModelStore(transport: MockTransport(payload), fileSystem: posix, endpoint: endpoint)
        let m = Model(repo: "desert-ant-labs/redact", revision: "v0.2.1", files: files)

        XCTAssertFalse(store.isDownloaded(m))
        try await store.download(m)
        XCTAssertTrue(store.isDownloaded(m))                     // present + hashes match, via POSIX
        XCTAssertTrue(posix.exists(store.location(of: m) + "/redact.mlmodelc/weights/weight.bin"))

        // Corruption caught, offline reuse is a no-op with a throwing transport.
        try posix.write(store.location(of: m) + "/redact.onnx", [UInt8](repeating: 0, count: 6000))
        XCTAssertFalse(store.isDownloaded(m))
        let offline = ModelStore(transport: OfflineTransport(), fileSystem: posix, endpoint: endpoint)
        XCTAssertFalse(offline.isDownloaded(m))                  // corrupt file, no net to fix it
    }

    func testResumesMissingFilesOnly() async throws {
        let a = [UInt8](repeating: 1, count: 100), b = [UInt8](repeating: 2, count: 200)
        let t = MockTransport([url("a.bin"): a, url("b.bin"): b])
        let store = ModelStore(transport: t, fileSystem: FoundationFileSystem(), endpoint: endpoint)
        let m = model(["a.bin", "b.bin"])
        try await store.download(m)
        XCTAssertEqual(t.downloadCount, 2)
        // Second call: everything present => no further downloads.
        try await store.download(m)
        XCTAssertEqual(t.downloadCount, 2)
    }
}
