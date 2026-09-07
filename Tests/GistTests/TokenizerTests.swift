import Foundation
import Testing
import DesertAnt
import TestSupport
@testable import Gist

// Model-backed (the tokenizer comes from the Hub), so guarded off wasm like the
// rest - `ModelFixture` does not exist there.
#if !os(WASI)

/// The Swift Unigram tokenizer must reproduce the training (model2vec) tokenizer's
/// ids exactly — the whole semantic stream depends on identical token ids.
@Suite(.modelBacked)
struct TokenizerTests {
    struct Case: Decodable { let text: String; let ids: [Int] }

    // The tokenizer is a 4.6 MB model file, so it comes from the Hub like every
    // other artifact here rather than being committed. Only the oracle (1.4 KB)
    // is a test resource.
    @Test func matchesPythonOracle() async throws {
        let files = try await GistFixture.loaded().files
        let tok = try #require(Tokenizer(bytes: try files.read(GistModel.tokenizer)))

        let oracleURL = try #require(Bundle.module.url(forResource: "gist-sdk-oracle", withExtension: "json"))
        let cases = try JSONDecoder().decode([Case].self, from: try Data(contentsOf: oracleURL))

        for c in cases {
            #expect(tok.encode(c.text) == c.ids, "tokenizer mismatch for \"\(c.text)\"")
        }
    }
}
#endif
