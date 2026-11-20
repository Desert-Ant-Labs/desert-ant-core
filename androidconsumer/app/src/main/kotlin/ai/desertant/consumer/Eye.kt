package ai.desertant.consumer

import ai.desertant.eye.Eye
import ai.desertant.eye.Options
import ai.desertant.eye.Part
import android.content.Context
import android.graphics.Bitmap

suspend fun eye(context: Context, photos: List<Bitmap>): List<List<Int>> = Eye(context).use { eye ->
    if (!eye.isDownloaded()) eye.download()
    val analyses = photos.map { eye.analyze(it, Options(parts = setOf(Part.PHOTO), maxFaces = 5)) }
    analyses.forEach { println("${it.kind} ${it.scores?.aesthetic} ${it.faces?.size}") }
    Eye.duplicates(analyses)
}
