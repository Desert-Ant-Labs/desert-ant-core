package ai.desertant.tongue.usage

/**
 * Wire format for the usage turnstile — a Kotlin port of desert-ant-core's
 * `Sources/Usage/Wire.swift`.
 *
 * The one billed signal is a `load` event. The server dedups by device
 * (COUNT DISTINCT deviceId per company per month) and SUMS callCount across
 * events, so emitting an extra `load` never over-bills and a session's calls can
 * be split across several events and still add up.
 *
 * JSON is written by hand. The shape is fixed and tiny, and this artifact declares
 * nothing beyond kotlin-stdlib — pulling in a JSON library for six fields would
 * put a real dependency on every consumer for no benefit. Field order follows core's declaration order so
 * the two ports produce byte-identical bodies. `UsageVectorTest.wireBodyMatchesCoreFieldOrder`
 * and the JavaScript suite's "the wire body matches core's field order" assert the
 * same literal string, so a reordered field in either port fails both.
 */
internal const val SDK_NAME: String = "tongue-kotlin"

internal data class SdkInfo(val name: String = SDK_NAME, val version: String)

internal data class AppInfo(val id: String)

internal data class IngestEvent(
    val name: String = "load",
    val deviceId: String,
    val callCount: Int? = null,
    val timestamp: String? = null,
    val context: Map<String, String>? = null,
)

internal data class IngestBody(
    val platform: String,
    val key: String? = null,
    val app: AppInfo? = null,
    val sdk: SdkInfo,
    val sentAt: String,
    val events: List<IngestEvent>,
)

/** Serialize to the exact JSON the ingest endpoint expects; nulls are omitted. */
internal fun buildBody(body: IngestBody): String = buildString {
    append('{')
    field("platform", body.platform); append(',')
    body.key?.let { field("key", it); append(',') }
    body.app?.let { append("\"app\":{"); field("id", it.id); append("},") }
    append("\"sdk\":{"); field("name", body.sdk.name); append(','); field("version", body.sdk.version); append("},")
    field("sentAt", body.sentAt); append(',')
    append("\"events\":[")
    body.events.forEachIndexed { index, event ->
        if (index > 0) append(',')
        append('{')
        field("name", event.name); append(',')
        field("deviceId", event.deviceId)
        event.callCount?.let { append(",\"callCount\":").append(it) }
        event.timestamp?.let { append(','); field("timestamp", it) }
        event.context?.let { ctx ->
            append(",\"context\":{")
            ctx.entries.forEachIndexed { i, (k, v) -> if (i > 0) append(','); field(k, v) }
            append('}')
        }
        append('}')
    }
    append("]}")
}

private fun StringBuilder.field(key: String, value: String) {
    quote(key); append(':'); quote(value)
}

/** RFC 8259 string escaping, including the control characters below 0x20. */
private fun StringBuilder.quote(value: String) {
    append('"')
    for (c in value) {
        when (c) {
            '"' -> append("\\\"")
            '\\' -> append("\\\\")
            '\n' -> append("\\n")
            '\r' -> append("\\r")
            '\t' -> append("\\t")
            '\b' -> append("\\b")
            '' -> append("\\f")
            else -> if (c < ' ') append("\\u%04x".format(c.code)) else append(c)
        }
    }
    append('"')
}
