import XCTest
import Foundation
import Checksum
@testable import ModelStore

/// Exercises the real Apple/Linux path end-to-end against the public
/// desert-ant-labs/redact repo: FoundationTransport HEAD (parses the LFS
/// x-linked-etag SHA-256), streamed download, SHA-256 verification, atomic move,
/// and offline reuse. Network + a real 13.7 MB file, so it is opt-in.
final class HubIntegrationTests: XCTestCase {
    func testRealDownloadAndVerify() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HF_INTEGRATION"] == "1",
                          "set HF_INTEGRATION=1 to run the network test")

        let tmp = NSTemporaryDirectory() + "dal-hf-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let store = ModelStore()  // Foundation (URLSession + FileManager)
        let m = Model(repo: "desert-ant-labs/redact", revision: "v0.2.1",
                      files: ["redact.onnx"], cacheDirectory: tmp)

        XCTAssertFalse(store.isDownloaded(m))
        try await store.download(m) { p in print("progress: \(Int(p.fraction * 100))%") }

        // isDownloaded re-hashed the file against the SHA-256 the store verified
        // against HF's x-linked-etag on download.
        XCTAssertTrue(store.isDownloaded(m))
        let bytes = try FoundationFileSystem().read(store.location(of: m) + "/redact.onnx")
        XCTAssertEqual(SHA256.hexDigest(bytes),
                       "04658a3d18bdc0944fceebc20fee7ed4b77489fe9331f599fab85875f8208cc8")

        // Offline reuse: no network, still valid.
        let offline = ModelStore(transport: OfflineTransport(), fileSystem: FoundationFileSystem())
        XCTAssertTrue(offline.isDownloaded(m))
    }
}
