package ai.desertant.consumer

import ai.desertant.who.Who
import android.content.Context

suspend fun who(context: Context, samples: FloatArray): List<Int> = Who(context).use { who ->
    if (!who.isDownloaded()) who.download()
    val diarization = who.diarize(samples, 16_000.0)
    diarization.turns.forEach { println("${it.speaker} ${it.start} ${it.duration}") }
    diarization.speakers(minimumShare = 0.05)
}
