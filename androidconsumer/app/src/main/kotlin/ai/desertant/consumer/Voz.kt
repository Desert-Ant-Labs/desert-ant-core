package ai.desertant.consumer

import ai.desertant.voz.Voz
import android.content.Context

suspend fun voz(context: Context, samples: FloatArray): String = Voz(context).use { voz ->
    if (!voz.isDownloaded()) voz.download()
    val transcription = voz.transcribe(samples, 16_000.0)
    transcription.words.forEach { println("${it.text} ${it.start} ${it.end}") }
    transcription.text
}
