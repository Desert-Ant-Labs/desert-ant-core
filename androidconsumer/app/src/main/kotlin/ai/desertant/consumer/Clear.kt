package ai.desertant.consumer

import ai.desertant.clear.ChannelMode
import ai.desertant.clear.Clear
import ai.desertant.clear.LoudnessPreset
import ai.desertant.clear.Mastering
import ai.desertant.clear.Options
import android.content.Context

suspend fun clear(context: Context, samples: FloatArray): FloatArray = Clear(context).use { clear ->
    if (!clear.isDownloaded()) clear.download()
    val options = Options(mastering = Mastering.of(LoudnessPreset.APPLE_PODCASTS), channelMode = ChannelMode.MONO)
    val result = clear.enhance(samples, 48_000.0, options)
    println("${result.measuredLufs} ${result.realtimeFactor}")
    result.samples
}
