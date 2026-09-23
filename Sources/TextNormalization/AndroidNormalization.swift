// NFKC via the Android host's java.text.Normalizer through CHostBridge, so the
// Swift core links no ICU. The platform libicu would force minSdk 31 (when its
// NDK headers became public), and bundling Foundation's ICU would add tens of
// megabytes; java.text.Normalizer exists since API 1. Until the JNI HostBridge
// installs the callback, text passes through unchanged, like Regex and JSON.
#if os(Android)
import CHostBridge
import CStrings

func nfkcNormalize(_ s: String) -> String {
    guard let ptr = s.withCString({ host_normalize($0) }) else { return s }
    defer { host_free(ptr) }
    return decodeCString(ptr)
}

// The host bridge normalizes NFKC only; a silent identity or NFKC here would change a model's bytes.
func nfcNormalize(_ s: String) -> String { preconditionFailure("nfc: no NFC bridge on Android") }
#endif
