import DesertAnt
import Testing
import TestSupport

@_spi(ClipBindings) @testable import Clips

/// Resolve the model the way a caller does, run it, and check the answer has a
/// shape. On every platform that runs model-backed tests, with no
/// `HF_INTEGRATION` gate: the gated `HubDownloadTests` was the only suite that
/// ever ran a Clips graph, so a normal `test:swift clips` passed on Linux and
/// Windows while the SDK could not drive the LiteRT files at all (first call:
/// `missing input 'args_0'`). The selection logic in `ClipTests.swift` needs no
/// artifact and cannot see that.
///
/// What this pins, per runtime:
///  - the tensor names the SDK binds (`ids`/`mask`/`disc` in,
///    `saliency`/`start_p`/`end_p`/`score` out) reach the graph, whatever the
///    export calls them (LiteRT: `args_N`/`output_N`);
///  - the element types the SDK builds are the ones the graph takes;
///  - the scorer's width is read from the graph, not the 128 fallback, or a
///    256-wide artifact is silently truncated.
///
/// `.serialized` and the shared fixture, which is the house pattern: see
/// `EarTests/SmokeTests.swift`.
#if !os(WASI)
@Suite(.serialized, .modelBacked)
struct SmokeTests {
    private func clips() async throws -> Clips {
        let files = try await ModelFixture.files(ClipModel.self)
        return Clips(directory: files.rootPath)
    }

    /// Long enough to propose spans; the content is a short talk with an
    /// obvious hook, so an empty result means the pipeline broke, not that the
    /// text was dull.
    static let transcript = [
        "Here's the mistake almost everyone makes with their first rental.",
        "They price it at what they need to cover the mortgage.",
        "The market does not care what your mortgage is.",
        "So the unit sits empty for two months.",
        "That's why an empty month costs more than a lower rent.",
        "Price it to fill, then raise it at renewal.",
        "The second year is where the return actually shows up.",
        "Most people quit before they get there.",
        "I made that mistake myself, and it cost me a whole season.",
        "Now I check three comparable listings before I set any price.",
        "It takes ten minutes and it is the best ten minutes of the year.",
        "If you remember one thing, remember that vacancy is the real cost.",
    ]

    @Test func resolvesTheModelAndRunsIt() async throws {
        let moments = try await clips().clips(in: Self.transcript)
        #expect(!moments.isEmpty)
        #expect(moments.map(\.score) == moments.map(\.score).sorted(by: >))
        #expect(moments.allSatisfy { $0.score.isFinite })
        #expect(moments.allSatisfy { (0...1).contains($0.percentile) })
        for moment in moments {
            #expect(moment.sentenceIDs == moment.sentenceIDs.sorted())
            #expect(moment.sentenceIDs.allSatisfy { Self.transcript.indices.contains($0) })
        }
    }

    /// The shipped package serves `select` at 128 and `score` at 256 (see
    /// `ClipModel.stem`). A runtime that cannot report the width falls back to
    /// 128 and truncates every candidate.
    @Test func readsEachGraphsWidthFromTheGraph() async throws {
        let files = try await ModelFixture.files(ClipModel.self)
        let assets = try await ModelAssets.clip(files: files, computeUnits: .cpuOnly)
        #expect(assets.selector.inputWidth(ClipModel.selector.inputs[0]) == 128)
        #expect(assets.scorer.inputWidth(ClipModel.scorer.inputs[0]) == 256)
    }
}
#endif
