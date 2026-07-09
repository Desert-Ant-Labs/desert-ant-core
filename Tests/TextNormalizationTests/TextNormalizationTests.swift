import XCTest
import TextNormalization

final class TextNormalizationTests: XCTestCase {
    func testCompatibilityDecomposition() {
        // Ligature and full-width forms fold under NFKC.
        XCTAssertEqual("\u{FB01}".nfkc, "fi")       // U+FB01 LATIN SMALL LIGATURE FI
        XCTAssertEqual("\u{FF21}".nfkc, "A")         // U+FF21 FULLWIDTH LATIN CAPITAL A
        XCTAssertEqual("\u{2460}".nfkc, "1")         // U+2460 CIRCLED DIGIT ONE
    }

    func testCanonicalComposition() {
        // Decomposed e + combining acute composes to precomposed e-acute.
        XCTAssertEqual("e\u{0301}".nfkc, "\u{00E9}")
    }

    func testIdempotentAndPlainAscii() {
        XCTAssertEqual("hello world".nfkc, "hello world")
        XCTAssertEqual("caf\u{00E9}".nfkc.nfkc, "caf\u{00E9}")
    }
}
