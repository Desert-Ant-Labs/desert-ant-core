// Unicode NFC, kept local so this package installs against a released
// desert-ant-core.
//
// The spec pins NFC, and core currently exposes only `String.nfkc` — NFKC folds
// compatibility characters (U+FB01 to "fi", U+00BD to "1/2"), which changes the
// character sequence and therefore every n-gram. An `nfc` addition is on core's
// add-nfc-normalization branch; once that is released this file becomes
// `import TextNormalization` and `text.nfc`, and the Android branch below can be
// deleted because core routes it through the host's java.text.Normalizer.
//
// Only Apple and Linux are covered here, which is all this package needs: Android
// consumers use the direct Kotlin port in packages/tongue-kotlin, not Swift, and
// the web uses packages/tongue-js. Sources/TongueAndroid — the C ABI kept for a
// future Node native binding — is the one target that will need core's version.
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
