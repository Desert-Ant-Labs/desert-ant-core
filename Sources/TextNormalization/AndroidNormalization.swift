// NFKC and NFC via the Android host's java.text.Normalizer through CHostBridge, so the
// Swift core links no ICU. The platform libicu would force minSdk 31 (when its
// NDK headers became public), and bundling Foundation's ICU would add tens of
// megabytes; java.text.Normalizer exists since API 1. Until the JNI HostBridge
// installs the callback, NFKC passes text through unchanged, like Regex and JSON.
#if os(Android)
import CHostBridge

func nfkcNormalize(_ s: String) -> String { normalize(s, with: host_normalize) ?? s }

// No pass-through for NFC: unchanged text would change a model's bytes without an error.
func nfcNormalize(_ s: String) -> String {
    guard let normalized = normalize(s, with: host_normalize_nfc) else {
        preconditionFailure("nfc: the Android host returned no NFC result. Use ai.desertant:core at the version of the model.")
    }
    return normalized
}

private func normalize(
    _ s: String,
    with host: (UnsafePointer<CChar>?, Int32, UnsafeMutablePointer<Int32>?) -> UnsafeMutablePointer<CChar>?
) -> String? {
    let bytes = Array(s.utf8)
    guard bytes.count <= Int(Int32.max) else { return nil }
    var length: Int32 = 0
    guard let ptr = bytes.withUnsafeBytes({ raw in
        host(raw.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(bytes.count), &length)
    }) else { return nil }
    defer { host_free(ptr) }
    return String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self), count: Int(length)), as: UTF8.self)
}
#endif
