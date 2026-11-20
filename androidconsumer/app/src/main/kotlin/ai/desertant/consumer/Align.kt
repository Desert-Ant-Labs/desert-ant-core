package ai.desertant.consumer

import ai.desertant.align.Align
import ai.desertant.align.Word
import android.content.Context

suspend fun align(context: Context, samples: FloatArray, words: List<Word>): Int = Align(context).use { align ->
    if (!align.isDownloaded()) align.download()
    if (!Align.isSupported("en")) return@use 0
    val refined = align.refine(samples, 16_000.0, words, language = "en")
    refined.forEach { println("${it.text} ${it.start} ${it.end} ${it.refined}") }
    refined.count { it.refined }
}
