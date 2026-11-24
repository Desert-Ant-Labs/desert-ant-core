package ai.desertant.androidtest

import android.content.res.AssetManager
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Load the PCM format used by the shared speech fixtures. */
internal fun AssetManager.readSpeechFixture(name: String): FloatArray {
    val bytes = open(name).use { it.readBytes() }
    val wav = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
    check(wav.getInt(0) == 0x46464952 && wav.getInt(8) == 0x45564157) { "expected a RIFF/WAVE fixture" }
    check(wav.getInt(12) == 0x20746d66 && wav.getInt(16) >= 16 &&
        wav.getShort(20).toInt() == 1 && wav.getShort(22).toInt() == 1 &&
        wav.getInt(24) == 16_000 && wav.getShort(34).toInt() == 16) {
        "expected mono 16 kHz PCM16"
    }
    var offset = 12
    while (offset <= wav.limit() - 8) {
        val id = wav.getInt(offset)
        val size = wav.getInt(offset + 4)
        val start = offset + 8
        check(size in 0..(wav.limit() - start)) { "invalid WAV chunk size" }
        if (id == 0x61746164) {
            check(size > 0 && size % 2 == 0)
            return FloatArray(size / 2) { index -> wav.getShort(start + 2 * index) / 32768f }
        }
        offset = start + size + (size % 2)
    }
    error("missing WAV data")
}
