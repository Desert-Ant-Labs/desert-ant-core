package ai.desertant.consumer

import ai.desertant.tongue.Reliability
import ai.desertant.tongue.Tongue
import android.content.Context

fun tongue(context: Context): String? {
    val detection = Tongue.bundled(context).detect("la casa", topK = 2)
    detection.candidates.forEach { println("${it.language} ${it.probability}") }
    return if (detection.reliability == Reliability.CONFIDENT) detection.language else null
}
