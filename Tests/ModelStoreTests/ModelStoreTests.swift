import XCTest
import Foundation
import Checksum
@testable import ModelStore

/// In-memory transport. `tree` lists the mock's files (reporting each file's
/// SHA-256 as an LFS hash unless `lfs: false`); `download` serves the bytes for
/// the requested path. `sizeOverride`/`shaOverride` simulate a corrupt tree.
final class MockTransport: ModelTransport, @unchecked Sendable {
    let files: [String: [UInt8]]   // repo-relative path -> bytes
    let lfs: Bool
    let sizeOverride: Int64?
    let shaOverride: String?
    private let lock = NSLock()
    private(set) var treeCount = 0
    private(set) var downloadCount = 0

    init(_ files: [String: [UInt8]], lfs: Bool = true, sizeOverride: Int64? = nil, shaOverride: String? = nil) {
        self.files = files; self.lfs = lfs; self.sizeOverride = sizeOverride; self.shaOverride = shaOverride
    }

    func tree(_ url: String) async throws -> [RemoteEntry] {
        lock.withLock { treeCount += 1 }
        return files.map { path, bytes in
            RemoteEntry(path: path, size: sizeOverride ?? Int64(bytes.count),
                        sha256: lfs ? (shaOverride ?? SHA256.hexDigest(bytes)) : nil)
        }
    }

    func download(_ url: String, to destinationPath: String, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        lock.withLock { downloadCount += 1 }
        guard let r = url.range(of: "/resolve/") else { throw ModelStoreError.io("bad url") }
        let rest = url[r.upperBound...]  // "<rev>/<path>"
        guard let slash = rest.firstIndex(of: "/") else { throw ModelStoreError.io("bad url") }
        let path = String(rest[rest.index(after: slash)...])
        guard let bytes = files[path] else { throw ModelStoreError.io("404 \(path)") }
        try FoundationFileSystem().write(destinationPath, bytes)
        onBytes(Int64(bytes.count))
    }
}

/// Throws on any call: proves the offline path never touches the network.
struct OfflineTransport: ModelTransport {
    func tree(_ url: String) async throws -> [RemoteEntry] { throw ModelStoreError.io("offline") }
    func download(_ url: String, to path: String, onBytes: @escaping @Sendable (Int64) -> Void) async throws { throw ModelStoreError.io("offline") }
}

final class LockedDouble: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0.0
    func set(_ v: Double) { lock.withLock { value = v } }
    func get() -> Double { lock.withLock { value } }
}

final class ModelStoreTests: XCTestCase {
    private var tmp: String!
    private let endpoint = "https://hub.test"

    override func setUp() { tmp = NSTemporaryDirectory() + "dal-modelstore-\(UUID().uuidString)" }
    override func tearDown() { try? FileManager.default.removeItem(atPath: tmp) }

    private func model(_ files: [String], fs: FileSystem? = nil) -> ModelSpec {
        ModelSpec(repo: "desert-ant-labs/redact", revision: "v0.2.1", files: files,
              cacheDirectory: fs == nil ? tmp : nil)
    }
    private func store(_ t: ModelTransport, _ fs: FileSystem = FoundationFileSystem()) -> ModelStore {
        ModelStore(transport: t, fileSystem: fs, endpoint: endpoint)
    }

    func testDownloadVerifyAndOfflineReuse() async throws {
        let payload = ["redact.onnx": [UInt8](repeating: 0x41, count: 5000),
                       "redact.mlmodelc/weights/weight.bin": [UInt8](repeating: 0x7, count: 800),
                       "labels.json": Array("{}".utf8)]
        let s = store(MockTransport(payload, lfs: false))  // labels/small files: no LFS hash
        let m = model(["redact.onnx", "redact.mlmodelc/weights/weight.bin", "labels.json"])

        XCTAssertFalse(s.isDownloaded(m))
        let last = LockedDouble()
        let downloaded = try await s.download(m) { p in last.set(p.fraction) }
        XCTAssertEqual(last.get(), 1.0, accuracy: 0.0001)
        XCTAssertEqual(try downloaded.read("labels.json"), payload["labels.json"])
        XCTAssertEqual(try downloaded.readString("labels.json"), "{}")
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.location(of: m) + "/redact.mlmodelc/weights/weight.bin"))
        XCTAssertTrue(s.isDownloaded(m))

        // Offline: manifest present + valid, so a throwing transport is untouched.
        let offline = store(OfflineTransport())
        XCTAssertTrue(offline.isDownloaded(m))
        try await offline.download(m)
    }

    func testFolderExpansion() async throws {
        // Pass a folder ("redact.mlmodelc/"); the tree expands it to its files.
        let payload = ["redact.mlmodelc/model.mil": [UInt8](repeating: 1, count: 500),
                       "redact.mlmodelc/coremldata.bin": [UInt8](repeating: 2, count: 60),
                       "redact.mlmodelc/weights/weight.bin": [UInt8](repeating: 3, count: 9000),
                       "redact_tokenizer.bin": [UInt8](repeating: 4, count: 300),
                       "README.md": Array("ignore me".utf8)]  // in repo but not requested
        let t = MockTransport(payload)
        let s = store(t)
        let m = model(["redact.mlmodelc/", "redact_tokenizer.bin"])

        try await s.download(m)
        XCTAssertEqual(t.downloadCount, 4)  // 3 mlmodelc files + tokenizer, NOT README
        XCTAssertTrue(s.isDownloaded(m))
        for f in ["redact.mlmodelc/model.mil", "redact.mlmodelc/coremldata.bin",
                  "redact.mlmodelc/weights/weight.bin", "redact_tokenizer.bin"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: s.location(of: m) + "/" + f), f)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.location(of: m) + "/README.md"))

        // Offline reuse works for a folder model (manifest recorded the expansion).
        XCTAssertTrue(store(OfflineTransport()).isDownloaded(m))
    }

    func testModelDistributionSelectsAndInstallsArtifacts() async throws {
        let payload = ["model.onnx": [UInt8](repeating: 3, count: 8),
                       "tokenizer.bin": [UInt8](repeating: 4, count: 5)]
        let distribution = ModelDistribution(
            repo: "desert-ant-labs/example",
            revision: "v1",
            platforms: [
                .linux: ModelPlatformFiles(
                    files: ["model.onnx", "tokenizer.bin"],
                    artifactPath: "model.onnx"
                )
            ]
        )
        let fs = FoundationFileSystem()
        let customStore = store(MockTransport(payload), fs)
        let spec = ModelSpec(
            repo: distribution.repo,
            revision: distribution.revision,
            files: distribution.currentPlatformFiles!.files,
            cacheDirectory: tmp
        )
        let files = try await customStore.download(spec)
        let installed = InstalledModel(files: files, artifactPath: files.path("model.onnx"))

        XCTAssertTrue(installed.artifactPath.hasSuffix("/model.onnx"))
        XCTAssertEqual(try installed.files.read("tokenizer.bin"), payload["tokenizer.bin"])

        let local = tmp + "/local"
        try fs.makeDirectory(local)
        try fs.write(local + "/model.onnx", payload["model.onnx"]!)
        try fs.write(local + "/tokenizer.bin", payload["tokenizer.bin"]!)
        let localInstall = try await distribution.load(from: local)
        XCTAssertEqual(localInstall.artifactPath, local + "/model.onnx")

        fs.remove(local + "/tokenizer.bin")
        do { _ = try await distribution.load(from: local); XCTFail("expected missing local file") }
        catch let error as ModelStoreError {
            guard case .localFileMissing = error else { return XCTFail("\(error)") }
        }
    }

    func testManifestIsSpecificToRequestedFiles() async throws {
        let payload = ["a.bin": [UInt8](repeating: 1, count: 4),
                       "b.bin": [UInt8](repeating: 2, count: 4)]
        let s = store(MockTransport(payload))
        let a = model(["a.bin"])
        let b = model(["b.bin"])

        try await s.download(a)
        XCTAssertTrue(s.isDownloaded(a))
        XCTAssertFalse(s.isDownloaded(b))
    }

    func testUnsafePathsAndTreeEntriesAreRejected() async throws {
        let s = store(MockTransport(["../escape": [1]]))
        do { try await s.download(model(["../escape"])); XCTFail("expected invalid spec") }
        catch let error as ModelStoreError {
            guard case .invalidSpec = error else { return XCTFail("\(error)") }
        }

        let unsafeTree = store(MockTransport(["weights/../escape": [1]]))
        let folder = model(["weights/"])
        do { try await unsafeTree.download(folder); XCTFail("expected invalid response") }
        catch let error as ModelStoreError {
            guard case .invalidResponse = error else { return XCTFail("\(error)") }
        }
    }

    func testMissingFileOrFolderThrows() async throws {
        let t = MockTransport(["redact.onnx": [UInt8](repeating: 1, count: 10)])
        let s = store(t)
        do { try await s.download(model(["nope.bin"])); XCTFail("expected notInRepo") }
        catch let e as ModelStoreError { if case .notInRepo = e {} else { XCTFail("\(e)") } }
        do { try await s.download(model(["missing.mlmodelc/"])); XCTFail("expected notInRepo") }
        catch let e as ModelStoreError { if case .notInRepo = e {} else { XCTFail("\(e)") } }
    }

    func testCorruptionIsDetectedAndReDownloaded() async throws {
        let good = [UInt8](repeating: 0x9, count: 4096)
        let t = MockTransport(["redact.onnx": good])
        let s = store(t)
        let m = model(["redact.onnx"])
        try await s.download(m)
        XCTAssertTrue(s.isDownloaded(m))

        try FoundationFileSystem().write(s.location(of: m) + "/redact.onnx", [UInt8](repeating: 0xFF, count: 4096))
        XCTAssertFalse(s.isDownloaded(m))   // always re-hashes
        try await s.download(m)
        XCTAssertEqual(t.downloadCount, 2)  // re-fetched
        XCTAssertTrue(s.isDownloaded(m))
    }

    func testSizeMismatchIsRejected() async throws {
        let t = MockTransport(["redact.onnx": [UInt8](repeating: 0x3, count: 2048)], sizeOverride: 9999)
        let s = store(t)
        let m = model(["redact.onnx"])
        do { try await s.download(m); XCTFail("expected integrity failure") }
        catch let e as ModelStoreError { if case .integrityCheckFailed = e {} else { XCTFail("\(e)") } }
        XCTAssertFalse(s.isDownloaded(m))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.location(of: m) + "/redact.onnx"))
    }

    func testHashMismatchIsRejected() async throws {
        let t = MockTransport(["redact.onnx": [UInt8](repeating: 0x3, count: 2048)],
                              shaOverride: String(repeating: "a", count: 64))
        let s = store(t)
        let m = model(["redact.onnx"])
        do { try await s.download(m); XCTFail("expected integrity failure") }
        catch let e as ModelStoreError { if case .integrityCheckFailed = e {} else { XCTFail("\(e)") } }
        XCTAssertFalse(s.isDownloaded(m))
    }

    func testPOSIXFileSystemBackend() async throws {
        // The Android FS backend is raw POSIX, identical on Linux.
        let payload = ["redact.onnx": [UInt8](repeating: 0x2b, count: 6000),
                       "redact.mlmodelc/weights/weight.bin": [UInt8](repeating: 0x11, count: 1234)]
        let posix = POSIXFileSystem(cacheRoot: tmp)
        let s = store(MockTransport(payload), posix)
        let m = ModelSpec(repo: "desert-ant-labs/redact", revision: "v0.2.1", files: Array(payload.keys))

        try await s.download(m)
        XCTAssertTrue(s.isDownloaded(m))
        XCTAssertTrue(posix.exists(s.location(of: m) + "/redact.mlmodelc/weights/weight.bin"))

        try posix.write(s.location(of: m) + "/redact.onnx", [UInt8](repeating: 0, count: 6000))
        XCTAssertFalse(s.isDownloaded(m))
    }
}
