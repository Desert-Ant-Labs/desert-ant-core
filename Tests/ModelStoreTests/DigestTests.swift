#if !os(WASI)
import Testing
import Foundation
@testable import ModelStore

/// Streaming the hash must not weaken what verification catches.
@Suite struct DigestTests {
    private func tmp(_ bytes: [UInt8]) -> String {
        let p = NSTemporaryDirectory() + "/dig-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: p, contents: Data(bytes))
        return p
    }

    @Test func digestMatchesWholeFileHash() throws {
        let fs = FoundationFileSystem()
        // Across a chunk boundary, which is where a streaming hash goes wrong.
        for size in [0, 1, 1023, 1 << 20, (1 << 20) + 1, 3 * (1 << 20) + 77] {
            var seed: UInt64 = 0x9E3779B97F4A7C15
            let bytes = (0..<size).map { _ -> UInt8 in
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(truncatingIfNeeded: seed >> 33)
            }
            let path = tmp(bytes)
            defer { try? FileManager.default.removeItem(atPath: path) }
            let d = try fs.digest(path)
            #expect(d.size == Int64(size), "size wrong at \(size)")
            #expect(d.sha256 == SHA256.hexDigest(bytes), "digest differs from whole-file hash at \(size)")
        }
    }

    @Test func digestNoticesASingleFlippedBit() throws {
        let fs = FoundationFileSystem()
        var bytes = [UInt8](repeating: 7, count: (1 << 20) + 500)
        let clean = tmp(bytes)
        defer { try? FileManager.default.removeItem(atPath: clean) }
        let before = try fs.digest(clean).sha256
        bytes[(1 << 20) + 100] ^= 0x01
        let dirty = tmp(bytes)
        defer { try? FileManager.default.removeItem(atPath: dirty) }
        #expect(try fs.digest(dirty).sha256 != before, "a flipped bit past the first chunk went unnoticed")
    }

    @Test func missingFileThrows() {
        #expect(throws: (any Error).self) { try FoundationFileSystem().digest("/nonexistent/nope") }
    }
}
#endif
