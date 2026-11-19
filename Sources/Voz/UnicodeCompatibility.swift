// Compiled only into the non-shipping compatibility harness.
#if DAL_ANDROID_UNICODE_TESTS
@_spi(AndroidUnicodeTests)
public func vozUnicodeFold(_ text: String) -> String { fold(text) }
@_spi(AndroidUnicodeTests)
public func vozUnicodeDetokenize(_ text: String) -> String { detokenize([text]) }
#endif
