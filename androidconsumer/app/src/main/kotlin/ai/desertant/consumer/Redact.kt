package ai.desertant.consumer

import ai.desertant.redact.Labels
import ai.desertant.redact.Options
import ai.desertant.redact.Redact
import android.content.Context

suspend fun redact(context: Context): String = Redact(context).use { redact ->
    if (!redact.isDownloaded()) redact.download()
    val redaction = redact.redaction("Call Ana on 555 0100", Options(minimumConfidence = 0.6, labels = Labels.DEFAULT))
    redaction.items.forEach { println("${it.label} ${it.placeholder} ${it.start}..${it.end}") }
    redaction.restore(redaction.redactedText)
}
