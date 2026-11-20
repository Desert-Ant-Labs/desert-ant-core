package ai.desertant.core.androidtest

/** Non-published adapter over the production tokenizer and feature implementations. */
object UnicodeBridge {
    init { System.loadLibrary("LiteRt"); System.loadLibrary("UnicodeAndroidTests") }
    @JvmStatic external fun check(host: Class<*>, operation: ByteArray, input: ByteArray, artifact: ByteArray): ByteArray
}
