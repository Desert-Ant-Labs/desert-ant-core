// Compiled only into the non-shipping compatibility harness.
#if DAL_ANDROID_UNICODE_TESTS
import DesertAnt
@_spi(AndroidUnicodeTests)
public func emoUnicodeFeatures(_ text: String) -> String {
    let (b, s, i) = NGram.encode(text, nBuckets: 65536, nHashes: 3, nImportance: 1024, maxFeatures: 256)
    return "[" + zip(zip(b, s), i).map { pair, importance in
        "[" + (pair.0.map(Int.init) + pair.1.map(Int.init) + [Int(importance)]).map(String.init).joined(separator: ",") + "]"
    }.joined(separator: ",") + "]"
}
#endif
