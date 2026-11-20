package ai.desertant.consumer

import ai.desertant.uhm.Bias
import ai.desertant.uhm.Options
import ai.desertant.uhm.Uhm
import android.content.Context

suspend fun uhm(context: Context, samples: FloatArray): Int = Uhm(context).use { uhm ->
    if (!uhm.isDownloaded()) uhm.download()
    val result = uhm.detect(samples, 16_000.0, Options(bias = Bias.BALANCED))
    result.fillers.forEach { println("${it.start} ${it.end} ${it.type} ${it.confidence}") }
    result.fillers.size
}
