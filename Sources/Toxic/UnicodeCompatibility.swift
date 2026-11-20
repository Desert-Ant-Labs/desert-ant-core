// Compiled only into the non-shipping compatibility harness.
#if DAL_ANDROID_UNICODE_TESTS
@_spi(AndroidUnicodeTests)
public func toxicUnicodeTokens(_ text: String, _ bytes: [UInt8]) -> [Int32]? {
    Tokenizer(bytes: bytes)?.encode(text)
}
#endif
