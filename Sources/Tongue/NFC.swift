// The spec pins NFC, not NFKC: NFKC folds compatibility characters (U+FB01 to
// "fi", U+00BD to "1/2"), which changes every n-gram.
// TODO: use `TextNormalization`'s `nfc` and delete this file.
//
// Only Apple and Linux are covered: Android and the web use the Kotlin and
// TypeScript ports in packages/, not Swift.
#if canImport(Foundation)
import Foundation

extension String {
    /// This string under Unicode Normalization Form C (canonical composition).
    var nfc: String { precomposedStringWithCanonicalMapping }
}
#else
extension String {
    /// No normalizer available: pass the text through unchanged, matching how
    /// core's host-delegated primitives behave before a host installs them.
    var nfc: String { self }
}
#endif
