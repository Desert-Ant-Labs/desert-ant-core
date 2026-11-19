package ai.desertant.consumer

import ai.desertant.ear.Ear
import ai.desertant.ear.Options
import android.content.Context

suspend fun ear(context: Context, samples: FloatArray): String? = Ear(context).use { ear ->
    if (!ear.isDownloaded()) ear.download()
    val detection = ear.identify(samples, 16_000.0, Options(windows = 3))
    detection.candidates.forEach { println("${it.language} ${it.probability}") }
    if (detection.isReliable) detection.language else null
}
