import Foundation
import XCTest
import DesertAnt
import TestSupport
@testable import Gist

// Model-backed (the tokenizer comes from the Hub), so guarded off wasm like the
// rest - `ModelFixture` does not exist there.
#if !os(WASI)

/// The Swift Unigram tokenizer must reproduce the training (model2vec) tokenizer's
/// ids exactly — the whole semantic stream depends on identical token ids.
final class TokenizerTests: XCTestCase {
    struct Case: Decodable { let text: String; let ids: [Int] }

    // The tokenizer is a 4.6 MB model file, so it comes from the Hub like every
    // other artifact here rather than being committed. Only the oracle (1.4 KB)
    // is a test resource.
    func testMatchesPythonOracle() async throws {
        try XCTSkipUnless(runsModelBackedTests, "model-backed tests do not run on iOS or Android")
        let files = try await ModelFixture.files(GistModel.self)
        let tok = try XCTUnwrap(Tokenizer(bytes: try files.read(GistModel.tokenizer)))

        let oracleURL = try XCTUnwrap(Bundle.module.url(forResource: "gist-sdk-oracle", withExtension: "json"))
        let cases = try JSONDecoder().decode([Case].self, from: try Data(contentsOf: oracleURL))

        for c in cases {
            XCTAssertEqual(tok.encode(c.text), c.ids, "tokenizer mismatch for \"\(c.text)\"")
        }
    }
}
#endif
