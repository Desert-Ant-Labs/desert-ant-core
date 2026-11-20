package ai.desertant.consumer

import ai.desertant.gist.Gist
import android.content.Context

suspend fun gist(context: Context): List<String> = Gist(context).use { gist ->
    if (!gist.isDownloaded()) gist.download()
    gist.classify("The match went to penalties", topK = 3).map { "${it.slug} ${it.name} ${it.score}" }
}
