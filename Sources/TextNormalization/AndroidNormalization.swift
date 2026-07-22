// NFKC via the Android host's java.text.Normalizer through CHostBridge, so the
// pure-Swift core links no ICU. Using the platform libicu natively would force
// the minSdk up to API 31 (that is when its NDK headers became public), and
// bundling Foundation's ICU would add tens of megabytes; delegating to the host
// (java.text.Normalizer exists since API 1) keeps the library small and lets the
// SDK support older Android. The runtime shim (the JNI HostBridge) installs the
// callback; until it does, text passes through unchanged, matching how the other
// host-delegated primitives (Regex/JSON) behave without a host.
#if os(Android)
import CHostBridge

func nfkcNormalize(_ s: String) -> String {
    guard let ptr = s.withCString({ host_normalize($0) }) else { return s }
    defer { host_free(ptr) }
    return String(cString: ptr)
}
#endif
