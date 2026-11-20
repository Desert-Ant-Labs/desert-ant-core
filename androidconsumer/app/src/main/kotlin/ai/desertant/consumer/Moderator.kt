package ai.desertant.consumer

import ai.desertant.moderator.Moderator
import ai.desertant.moderator.Options
import ai.desertant.moderator.Policy
import ai.desertant.moderator.Quality
import android.content.Context
import android.graphics.Bitmap

suspend fun moderator(context: Context, photo: Bitmap): Boolean = Moderator(context).use { moderator ->
    if (!moderator.isDownloaded()) moderator.download()
    val moderation = moderator.analyze(photo, Options(threshold = 0.5, policy = Policy.STANDARD, quality = Quality.FAST))
    println("${moderation.score} ${moderation.regions.nude}")
    moderation.isNSFW
}
