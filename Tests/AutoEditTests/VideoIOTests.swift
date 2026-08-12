import Foundation
import Testing
@testable import AutoEdit

struct ExportNames {
    /// A folder that cleans itself up.
    private func withTemporaryFolder(_ body: (URL) throws -> Void) rethrows {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try body(folder)
    }

    @Test func aFreePathIsUsedAsItIs() {
        withTemporaryFolder { folder in
            let wanted = folder.appending(path: "clip.mp4")
            #expect(VideoIO.firstFreeName(from: wanted) == wanted)
        }
    }

    @Test func writingAgainStepsAsideRatherThanReplacingWhatIsThere() {
        withTemporaryFolder { folder in
            let taken = folder.appending(path: "clip.mp4")
            FileManager.default.createFile(atPath: taken.path(percentEncoded: false), contents: nil)

            let free = VideoIO.firstFreeName(from: taken)
            #expect(free.lastPathComponent == "clip-2.mp4")
        }
    }

    @Test func theSuffixCountsUpPastTheFirstTaken() {
        withTemporaryFolder { folder in
            for name in ["clip.mp4", "clip-2.mp4", "clip-3.mp4"] {
                FileManager.default.createFile(
                    atPath: folder.appending(path: name).path(percentEncoded: false), contents: nil)
            }

            let free = VideoIO.firstFreeName(from: folder.appending(path: "clip.mp4"))
            #expect(free.lastPathComponent == "clip-4.mp4")
        }
    }

    @Test func theExtensionIsKept() {
        withTemporaryFolder { folder in
            let taken = folder.appending(path: "clip.mov")
            FileManager.default.createFile(atPath: taken.path(percentEncoded: false), contents: nil)

            #expect(VideoIO.firstFreeName(from: taken).pathExtension == "mov")
        }
    }
}
