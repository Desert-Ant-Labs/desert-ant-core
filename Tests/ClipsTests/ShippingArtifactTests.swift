#if canImport(CoreML) && !os(WASI)
import Foundation
import Testing
import DesertAnt
@_spi(ClipBindings) @testable import Clips

/// CLAUDE.md rule 11, as a test: decode real output from the artifact that
/// ships, through the consumer surface, before anything is pushed.
///
/// The rest of `ClipsTests` runs against a 24 KB weightless fixture. That is the
/// right shape for testing the loading contract - it proves a path names the
/// file and not the graph - but it deliberately does not carry weights, so a
/// green run of that suite says nothing about whether the shipping 281 MB
/// package produces clips a reader would accept. The distinction is the one
/// rule 11 exists for: a prompt-identity check validates the prompt, not the
/// parser, and a fixture check validates the loader, not the model.
///
/// Opt in by pointing these at a resolved model directory and the reference
/// transcripts, because the assets are 268 MB and not in the repo:
///
///     DAL_CLIP_REAL_MODEL_DIR=<dir with clips.mlmodelc + clip_tokenizer.bin> \
///     DAL_CLIP_REAL_TRANSCRIPTS=<clips-training/release/clip/test_transcripts.json> \
///     swift test --filter ShippingArtifact
///
/// Build the two assets with:
///
///     python python/build_tokenizer_bin.py release/clip/tokenizer/tokenizer.json \
///            -o <dir>/clip_tokenizer.bin
///     xcrun coremlcompiler compile \
///            release/clip-mf/mf/int8_linear_perchannel.mlpackage <dir>
///     mv <dir>/int8_linear_perchannel.mlmodelc <dir>/clips.mlmodelc
@Suite(.enabled(if: realAssetsPresent, "set DAL_CLIP_REAL_MODEL_DIR + DAL_CLIP_REAL_TRANSCRIPTS"))
struct ShippingArtifactTests {

    /// Real weights, real vocab, real transcripts, through `Model.clips(in:)`.
    ///
    /// The assertions are the ones a consumer's correctness depends on, not a
    /// quality bar: quality is settled by blind reads, and no test can stand in
    /// for one. What this pins is that the shipping bytes produce *decodable*
    /// clips - indices addressable in the caller's own array, text that is not
    /// empty, an ordering the API promises, and no overlap between moments.
    /// Every one of those has been wrong at some point in this model's history
    /// while a numeric gate stayed green.
    @Test func theShippingPackageProducesDecodableClips() async throws {
        let model = try Model(assets: await ModelAssets.clip(files: try realModelDirectory()))
        var totalClips = 0

        for sample in try referenceTranscripts() {
            let transcript = sample.sentences
            // `limit: nil` = the duration curve, i.e. what the model itself would emit. Rule 11 is
            // about whether the shipping bytes decode, so it should not be measured through a
            // product ceiling that a host can change.
            let moments = try await model.clips(in: transcript, limit: nil)

            #expect(!moments.isEmpty,
                    "\(sample.stratum)/\(transcript.count) sentences returned no clips at all")
            totalClips += moments.count

            for moment in moments {
                #expect(!moment.sentenceIDs.isEmpty, "a clip with no sentences is not decodable")
                #expect(moment.sentenceIDs.allSatisfy { transcript.indices.contains($0) },
                        "sentence id outside the caller's transcript: \(moment.sentenceIDs)")
                #expect(moment.sentenceIDs == Array(moment.sentenceIDs.sorted()),
                        "sentence ids must be ascending to slice a transcript with")
                #expect(!moment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "empty clip text decodes to nothing a user can watch")
                #expect(moment.estimatedDurationSec > 0)
                #expect(moment.score.isFinite, "a NaN score would sort arbitrarily")
            }

            // Rank order is part of the API: callers take the first N.
            #expect(moments.map(\.score) == moments.map(\.score).sorted(by: >),
                    "\(sample.stratum): clips must come back best-first")

            // Non-overlapping is the product promise the DP exists to keep.
            let spans = moments.map { ($0.sentenceIDs.first!, $0.sentenceIDs.last!) }
                .sorted { $0.0 < $1.0 }
            for (earlier, later) in zip(spans, spans.dropFirst()) {
                #expect(earlier.1 < later.0,
                        "\(sample.stratum): clips overlap at \(earlier) / \(later)")
            }
        }

        #expect(totalClips > 0)
    }

    // MARK: assets

    private struct Sample: Decodable {
        let stratum: String
        let sentences: [String]
    }

    private func referenceTranscripts() throws -> [Sample] {
        let path = try #require(ProcessInfo.processInfo.environment["DAL_CLIP_REAL_TRANSCRIPTS"])
        return try JSONDecoder().decode([Sample].self,
                                        from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func realModelDirectory() throws -> StoredModel {
        let root = try #require(ProcessInfo.processInfo.environment["DAL_CLIP_REAL_MODEL_DIR"])
        for asset in [ClipModel.coreML, ClipModel.tokenizer] {
            #expect(FileManager.default.fileExists(atPath: root + "/" + asset),
                    "\(asset) missing from \(root); see this file's header for how to build it")
        }
        return try StoredModel.platformLocal(rootPath: root)
    }
}

private let realAssetsPresent: Bool = {
    let env = ProcessInfo.processInfo.environment
    guard let dir = env["DAL_CLIP_REAL_MODEL_DIR"], env["DAL_CLIP_REAL_TRANSCRIPTS"] != nil
    else { return false }
    return FileManager.default.fileExists(atPath: dir + "/" + ClipModel.coreML)
}()
#endif
