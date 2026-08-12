#if !os(WASI)
import XCTest
import TestSupport
@testable import Clips

/// The Hub integration path, shared with every other model SDK and gated on
/// `HF_INTEGRATION=1` so a normal run needs no network.
///
/// This is the only end-to-end test Clips has today, and it is skipped by
/// default: the published repo carries no tag whose file names match
/// `ClipModel` yet (see the `revision` note there), so there is nothing to
/// download. The selection logic that does not need an artifact is covered
/// unconditionally in `ClipTests.swift`.
final class HubDownloadTests: XCTestCase {
    func testDownloadThenSelect() async throws {
        try await HubDownloadScenario.run(
            ClipModel.self,
            make: { Clips(directory: $0) },
            isDownloaded: { $0.isDownloaded() },
            download: { try await $0.download(progress: $1) }
        ) { clip, cached in
            let transcript = [
                "Here's the mistake almost everyone makes with their first rental.",
                "They price it at what they need to cover the mortgage.",
                "The market does not care what your mortgage is.",
                "So the unit sits empty for two months.",
                "That's why an empty month costs more than a lower rent.",
                "Price it to fill, then raise it at renewal.",
                "The second year is where the return actually shows up.",
                "Most people quit before they get there.",
            ]
            let moments = try await clip.clips(in: transcript)
            XCTAssertFalse(moments.isEmpty)
            XCTAssertEqual(moments.map(\.score), moments.map(\.score).sorted(by: >))
            XCTAssertTrue(moments.allSatisfy { (0...1).contains($0.percentile) })
            for moment in moments {
                XCTAssertEqual(moment.sentenceIDs, Array(moment.sentenceIDs.sorted()))
                XCTAssertTrue(moment.sentenceIDs.allSatisfy { transcript.indices.contains($0) })
            }

            let limited = try await cached.clips(in: transcript, limit: 1)
            XCTAssertLessThanOrEqual(limited.count, 1)
        }
    }
}
#endif
