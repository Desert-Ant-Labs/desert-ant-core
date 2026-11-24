package ai.desertant.consumer

import ai.desertant.title.Card
import ai.desertant.title.Titles
import android.content.Context

suspend fun title(context: Context): Card = Titles(context).use { titles ->
    if (!titles.isDownloaded()) titles.download()
    titles.describe("The public library will open on Sundays starting next month.")
}
