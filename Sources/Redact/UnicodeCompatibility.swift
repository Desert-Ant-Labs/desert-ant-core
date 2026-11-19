// Compiled only into the non-shipping compatibility harness.
#if DAL_ANDROID_UNICODE_TESTS
@_spi(AndroidUnicodeTests)
public func redactUnicodeSpans(_ text: String) -> String {
    "[" + Deterministic.detect(text, enabled: Deterministic.owned.union(["PHONE"])).map { "[\($0.start),\($0.end),\"\($0.label)\"]" }.joined(separator: ",") + "]"
}
@_spi(AndroidUnicodeTests)
public func redactUnicodeTokens(_ text: String, _ bytes: [UInt8]) -> [Int]? {
    Tokenizer(bytes: bytes)?.tokenize(text).map(\.id)
}
#endif
