#if os(Android) && DAL_ANDROID_UNICODE_TESTS
import Android
import HostBridge
import JSON
@_spi(AndroidUnicodeTests) import Emo
@_spi(AndroidUnicodeTests) import Gist
@_spi(AndroidUnicodeTests) import Redact
@_spi(AndroidUnicodeTests) import Toxic
@_spi(AndroidUnicodeTests) import Voz

@_cdecl("Java_ai_desertant_core_androidtest_UnicodeBridge_check")
public func unicodeCheck(_ env: HostEnv, _ clazz: jclass?, _ host: jclass?, _ operation: jbyteArray?, _ input: jbyteArray?, _ artifact: jbyteArray?) -> jbyteArray? {
    installHostBridge(env, host)
    let op = String(decoding: hostCopyBytes(env, operation) ?? [], as: UTF8.self)
    let text = String(decoding: hostCopyBytes(env, input) ?? [], as: UTF8.self)
    let bytes = hostCopyBytes(env, artifact) ?? []
    let result: String
    switch op {
    case "voz.fold": result = (try? JSONEncoder().encodeToString(vozUnicodeFold(text))) ?? "null"
    case "voz.detokenize": result = (try? JSONEncoder().encodeToString(vozUnicodeDetokenize(text))) ?? "null"
    case "emo.features": result = emoUnicodeFeatures(text)
    case "gist.tokens": result = gistUnicodeTokens(text, bytes).map { String(describing: $0) } ?? "null"
    case "gist.features": result = String(describing: gistUnicodeFeatures(text, 8192))
    case "toxic.tokens": result = toxicUnicodeTokens(text, bytes).map { String(describing: $0) } ?? "null"
    case "redact.spans": result = redactUnicodeSpans(text)
    case "redact.tokens": result = redactUnicodeTokens(text, bytes).map { String(describing: $0) } ?? "null"
    default: result = "null"
    }
    return hostMakeBytes(env, Array(result.utf8))
}
#endif
