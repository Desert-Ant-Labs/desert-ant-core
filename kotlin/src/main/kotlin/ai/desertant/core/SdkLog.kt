package ai.desertant.core

import android.util.Log

/**
 * Where every SDK message ends up, the native core's and the Kotlin side's:
 * the app's [DesertAnt.logger] when it set one, else logcat under the
 * `DesertAnt` tag. It does not filter by [DesertAnt.logLevel]: the native core
 * filters before it calls, and [DesertAnt.checkHealth] reports whatever the
 * level, since the app asked for it.
 */
internal object SdkLog {
    const val TAG = "DesertAnt"

    fun write(level: LogLevel, source: String, message: String) {
        val logger = DesertAnt.logger
        if (logger != null) {
            logger(level, source, message)
            return
        }
        val text = "$source: $message"
        when (level) {
            LogLevel.DEBUG -> Log.d(TAG, text)
            LogLevel.INFO -> Log.i(TAG, text)
            LogLevel.WARNING -> Log.w(TAG, text)
            LogLevel.ERROR, LogLevel.OFF -> Log.e(TAG, text)
        }
    }
}
