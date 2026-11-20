package ai.desertant.consumer

import ai.desertant.emo.Emo
import ai.desertant.emo.EmojiSkinTone
import android.content.Context

suspend fun emo(context: Context): List<String> = Emo(context).use { emo ->
    if (!emo.isDownloaded()) emo.download()
    emo.suggestions("Dinner with friends", limit = 3, skinTone = EmojiSkinTone.MEDIUM)
        .map { "${it.emoji} ${it.confidence}" }
}
