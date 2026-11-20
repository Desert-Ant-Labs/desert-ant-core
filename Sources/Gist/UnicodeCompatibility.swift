// Compiled only into the non-shipping compatibility harness.
#if DAL_ANDROID_UNICODE_TESTS
@_spi(AndroidUnicodeTests)
public func gistUnicodeTokens(_ text: String, _ bytes: [UInt8]) -> [Int]? {
    Tokenizer(bytes: bytes)?.encode(text)
}
@_spi(AndroidUnicodeTests)
public func gistUnicodeFeatures(_ text: String, _ dim: Int) -> [Float] { NGrams.features(text, dim: dim) }
#endif
