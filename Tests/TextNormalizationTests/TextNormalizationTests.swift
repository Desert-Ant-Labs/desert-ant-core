import Testing
import TextNormalization

struct TextNormalizationTests {
    @Test func compatibilityDecomposition() {
        // Ligature and full-width forms fold under NFKC.
        #expect("\u{FB01}".nfkc == "fi")       // U+FB01 LATIN SMALL LIGATURE FI
        #expect("\u{FF21}".nfkc == "A")         // U+FF21 FULLWIDTH LATIN CAPITAL A
        #expect("\u{2460}".nfkc == "1")         // U+2460 CIRCLED DIGIT ONE
    }

    @Test func canonicalComposition() {
        // Decomposed e + combining acute composes to precomposed e-acute.
        #expect("e\u{0301}".nfkc == "\u{00E9}")
    }

    @Test func idempotentAndPlainAscii() {
        #expect("hello world".nfkc == "hello world")
        #expect("caf\u{00E9}".nfkc.nfkc == "caf\u{00E9}")
    }
}
