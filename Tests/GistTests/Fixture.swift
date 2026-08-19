import Foundation
import DesertAnt
import TestSupport
@_spi(GistBindings) @testable import Gist

#if !os(WASI)
/// One resolve and one model build for the whole GistTests target.
///
/// Gist is the most expensive model here to load: resolving verifies 71 MB and
/// costs ~9 s, and building the 67 MB embedding table another ~2 s, while a
/// classify costs ~1 ms. So the suite's runtime is entirely a function of how
/// many times it loads, and nothing else.
///
/// `Gist()` resolves through its own `LoadedModel`, which does not share
/// `ModelFixture`'s memo — so a suite that used both paid the 9 s twice. Building
/// the tagger from the fixture's already-resolved files collapses that to one,
/// shared with `PipelineTests`, which needs the same files for its oracles.
///
/// The public `Gist()` construction path is deliberately not exercised here: it
/// resolves through its own `LoadedModel`, and even `isDownloaded()` costs the
/// full 9 s, because `ModelStore.isDownloaded` re-reads and SHA256s every file
/// on each call. The resolve/download machinery is core's and is covered by the
/// Emo and Redact `HubDownloadTests`, so paying for it again here buys nothing.
enum GistFixture {
    struct Loaded {
        /// The resolved model directory, for tests that read sidecars directly.
        let files: StoredModel
        /// A ready tagger over those files. Shared: do not mutate.
        let gist: Gist
    }

    // A static `let` Task is created lazily and exactly once, so concurrent
    // suites await the same load rather than racing to repeat it.
    private static let load = Task<Loaded, Error> {
        let files = try await ModelFixture.files(GistModel.self)
        return Loaded(
            files: files,
            gist: Gist(assets: try await ModelAssets.gist(files: files, variant: .default)))
    }

    static func loaded() async throws -> Loaded { try await load.value }
}
#endif
