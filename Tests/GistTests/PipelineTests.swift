import Foundation
import XCTest
import DesertAnt
import TestSupport
@testable import Gist

// The oracle comparison needs the Hub-downloaded tokenizer and embedding table,
// and `ModelFixture` is itself `#if !os(WASI)` (the wasm harness has no model
// store), so the whole suite is guarded like every other model-backed one.
#if !os(WASI)

/// The semantic (embedding pool) and lexical (hashed n-gram) streams must match
/// the Python/gist-js reference exactly — they are the head's input. (The head
/// itself is validated separately: the LiteRT .tflite is bit-identical to ONNX.)
final class PipelineTests: XCTestCase {
    struct Case: Decodable { let text: String; let emb: [Float]; let ngram_nz: [String: Float] }

    // The tokenizer and the 67 MB embedding table come from the Hub rather than
    // from committed fixtures — the same files a user gets, and the reason this
    // suite is model-backed. Only the 53 KB oracle is a test resource. Resolved
    // through `GistFixture` so the whole target verifies those files once.
    func testSemanticAndLexicalStreams() async throws {
        try XCTSkipUnless(runsModelBackedTests, "model-backed tests do not run on iOS or Android")
        let files = try await GistFixture.loaded().files

        let tok = try XCTUnwrap(Tokenizer(bytes: try files.read(GistModel.tokenizer)))
        let embedding = try Embedding(
            rows: try files.read(GistModel.embedding),
            metaJSON: try files.readString(GistModel.embeddingMeta))

        let oracleURL = try XCTUnwrap(Bundle.module.url(forResource: "gist-feature-oracle", withExtension: "json"))
        let cases = try JSONDecoder().decode([Case].self, from: try Data(contentsOf: oracleURL))

        for c in cases {
            // semantic stream
            let sem = embedding.pool(ids: tok.encode(c.text))
            XCTAssertEqual(sem.count, c.emb.count, "emb dim for \"\(c.text)\"")
            var maxDiff: Float = 0
            for (a, b) in zip(sem, c.emb) { maxDiff = max(maxDiff, abs(a - b)) }
            XCTAssertLessThan(maxDiff, 1e-3, "semantic embedding drift for \"\(c.text)\"")

            // lexical stream
            let ng = NGrams.features(c.text, dim: 8192)
            for (idxStr, expected) in c.ngram_nz {
                let i = Int(idxStr)!
                XCTAssertEqual(ng[i], expected, accuracy: 1e-4, "n-gram[\(i)] for \"\(c.text)\"")
            }
            let nz = ng.enumerated().filter { $0.element != 0 }.count
            XCTAssertEqual(nz, c.ngram_nz.count, "n-gram nonzero count for \"\(c.text)\"")
        }
    }
}
#endif
