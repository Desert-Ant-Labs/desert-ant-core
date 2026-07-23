// Foundation transport/filesystem only (see ModelStoreTests); WASI-excluded.
#if !os(WASI)
import Testing
import Foundation
import Checksum
@testable import ModelStore

/// Exercises the real Apple/Linux path end-to-end against the public
/// desert-ant-labs/redact repo: FoundationTransport HEAD (parses the LFS
/// x-linked-etag SHA-256), streamed download, SHA-256 verification, atomic move,
/// and offline reuse. Network + a real 13.7 MB file, so it is opt-in.
struct HubIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HF_INTEGRATION"] == "1"))
    func realDownloadAndVerify() async throws {
        let tmp = NSTemporaryDirectory() + "dal-hf-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let store = ModelStore()  // Foundation (URLSession + FileManager)
        // A folder (expanded via the tree API) + an exact file.
        let m = ModelSpec(repo: "desert-ant-labs/redact", revision: "v0.2.1",
                      files: ["redact.mlmodelc/", "README.md"], cacheDirectory: tmp)

        #expect(!store.isDownloaded(m))
        try await store.download(m) { p in print("progress: \(Int(p.fraction * 100))%") }
        #expect(store.isDownloaded(m))

        // The whole .mlmodelc directory materialized, nested paths and all.
        let dir = store.location(of: m) + "/redact.mlmodelc"
        for f in ["model.mil", "coremldata.bin", "analytics/coremldata.bin", "weights/weight.bin"] {
            #expect(FileManager.default.fileExists(atPath: dir + "/" + f), "\(f)")
        }
        // The large LFS weight verifies to its known SHA-256.
        let weight = try FoundationFileSystem().read(dir + "/weights/weight.bin")
        #expect(SHA256.hexDigest(weight) ==
                "43fcbcd6be73b4d46bf797f4321f4d8289254901c36d28bafe558125cd3347fd")

        // Offline reuse works for the folder model (manifest recorded the expansion).
        let offline = ModelStore(transport: OfflineTransport(), fileSystem: FoundationFileSystem())
        #expect(offline.isDownloaded(m))
    }
}
#endif
