package ai.desertant.consumer

import ai.desertant.toxic.Label
import ai.desertant.toxic.Options
import ai.desertant.toxic.Toxic
import android.content.Context

suspend fun toxic(context: Context): Boolean = Toxic(context).use { toxic ->
    if (!toxic.isDownloaded()) toxic.download()
    val analysis = toxic.analyze("you are great", Options())
    println("${analysis.content} ${analysis.targets} ${analysis.score(Label.entries.first())}")
    analysis.isToxic
}
