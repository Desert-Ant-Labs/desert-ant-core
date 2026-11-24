package ai.desertant.tongue.license

/** The `sdk` a license grant names, as Sources/Usage/Wire.swift sends it. */
internal const val SDK_NAME = "desert-ant-core"
internal const val SDK_VERSION = "6.0.0"

internal const val MODEL_ID = "tongue"
internal const val MODEL_VERSION = "v1.0.0"

internal const val DEFAULT_LICENSE_ENDPOINT = "https://events.desertant.com/api/v1"
internal const val HOUR_MS = 60L * 60 * 1000
internal const val DAY_MS = 24 * HOUR_MS
internal const val LICENSE_NETWORK_RETRY_MS = 5L * 60 * 1000
internal const val LICENSE_MIN_BACKOFF_MS = 60L * 1000
internal const val LICENSE_MAX_BACKOFF_MS = 6 * HOUR_MS
internal const val LICENSE_TERMINAL_WAIT_MS = DAY_MS
internal const val LICENSE_TIMEOUT_MS = 10_000

internal const val CORE_INSTALL_ID_WAIT_MS = 10L * 1000
internal const val CORE_INSTALL_ID_POLL_MS = 100L

internal const val DEVICE_LICENSE_REQUEST_HOLD_MS = 60L * 1000
internal const val DEVICE_LICENSE_CAPACITY = 200_000
internal const val DEVICE_LICENSE_QUEUE_LIMIT = 10_000
internal const val DEVICE_LICENSE_BATCH_ITEMS = 100
internal const val DEVICE_LICENSE_SINGLE_GRANTS_MS = HOUR_MS
internal const val DEVICE_LICENSE_WAIT_MS = 10L * 1000
internal const val DEVICE_LICENSE_FLUSH_MS = 10L * 1000

internal const val RUN_ON_A_SERVER_GUIDE = "https://github.com/Desert-Ant-Labs/desert-ant-core/blob/main/docs/notes/server.md"

internal class LicenseIdentity(val appId: String, val apiKey: String?, val platform: String) {
    val namespace: String get() = apiKey ?: appId
}

internal class HttpReply(val status: Int, val body: ByteArray, val retryAfter: String?)

internal enum class LicenseResponseAction(val wire: String) {
    DONE("done"), TERMINAL("terminal"), RETRY("retry"), RETRY_NETWORK("retry-network")
}

internal fun licenseResponseAction(status: Int, body: ByteArray): LicenseResponseAction {
    if (status == 0) return LicenseResponseAction.RETRY_NETWORK
    if (status in 200..299) return LicenseResponseAction.DONE
    if (status == 400 || status == 422) {
        val error = Json.parseObject(body.toString(Charsets.UTF_8))?.get("error") as? String
        if (!error.isNullOrEmpty()) return LicenseResponseAction.TERMINAL
    }
    return LicenseResponseAction.RETRY
}

internal fun licenseRetryAfter(reply: HttpReply): Long? {
    val parts = (reply.retryAfter ?: return null).split(Regex("\\s+")).filter { it.isNotEmpty() }
    val seconds = parts.singleOrNull()?.toLongOrNull()?.takeIf { it >= 0 } ?: return null
    return if (seconds >= LICENSE_MAX_BACKOFF_MS / 1000) LICENSE_MAX_BACKOFF_MS else seconds * 1000
}

internal fun licenseBackoff(attempt: Int, retryAfter: Long?, jitter: (Long) -> Long): Long {
    val ceiling = minOf(LICENSE_MAX_BACKOFF_MS, LICENSE_MIN_BACKOFF_MS shl attempt.coerceIn(0, 16))
    val delay = jitter(ceiling)
    return if (retryAfter == null) delay else minOf(LICENSE_MAX_BACKOFF_MS, maxOf(delay, retryAfter))
}

internal fun grantBody(installId: String, who: LicenseIdentity): ByteArray =
    (
        "{\"installId\":${Json.quote(installId)},\"model\":${Json.quote(MODEL_ID)}," +
            "\"modelVersion\":${Json.quote(MODEL_VERSION)}," +
            "\"sdk\":{\"name\":${Json.quote(SDK_NAME)},\"version\":${Json.quote(SDK_VERSION)}}," +
            "\"platform\":${Json.quote(who.platform)},\"app\":{\"id\":${Json.quote(who.appId)}}}"
        ).toByteArray(Charsets.UTF_8)

internal fun batchBody(installIds: List<String>, who: LicenseIdentity): ByteArray {
    val items = installIds.joinToString(",") {
        "{\"installId\":${Json.quote(it)},\"model\":${Json.quote(MODEL_ID)},\"modelVersion\":${Json.quote(MODEL_VERSION)}}"
    }
    return (
        "{\"sdk\":{\"name\":${Json.quote(SDK_NAME)},\"version\":${Json.quote(SDK_VERSION)}}," +
            "\"platform\":${Json.quote(who.platform)},\"app\":{\"id\":${Json.quote(who.appId)}},\"items\":[$items]}"
        ).toByteArray(Charsets.UTF_8)
}

/** Each item's token (null for an item without one) and the server time of a batch answer, or null when it cannot be read. */
internal fun batchAnswer(body: ByteArray): Pair<List<String?>, String?>? {
    val reply = Json.parseObject(body.toString(Charsets.UTF_8)) ?: return null
    val serverTime = reply["serverTime"]
    if (serverTime != null && serverTime !is String) return null
    val tokens = (reply["results"] as? List<*> ?: return null).map { result ->
        val token = (result as? Map<*, *> ?: return null)["token"]
        if (token != null && token !is String) return null
        token
    }
    return tokens to serverTime
}

/** The token and the server time of a grant answer, or null when it has no token. */
internal fun grantAnswer(body: ByteArray): Pair<String, String?>? {
    val reply = Json.parseObject(body.toString(Charsets.UTF_8)) ?: return null
    val token = reply["token"] as? String ?: return null
    val serverTime = reply["serverTime"]
    if (serverTime != null && serverTime !is String) return null
    return token to serverTime
}

internal fun parseISO8601(text: String): Long? {
    val bytes = text.toByteArray(Charsets.UTF_8)
    fun number(start: Int, count: Int): Long? {
        var value = 0L
        for (index in start until start + count) {
            val digit = bytes[index] - '0'.code
            if (digit !in 0..9) return null
            value = value * 10 + digit
        }
        return value
    }
    fun isChar(index: Int, char: Char) = bytes[index] == char.code.toByte()
    if (bytes.size < 20 || !isChar(4, '-') || !isChar(7, '-') || !isChar(10, 'T') ||
        !isChar(13, ':') || !isChar(16, ':') || !isChar(bytes.size - 1, 'Z')
    ) return null
    val year = number(0, 4) ?: return null
    val month = number(5, 2) ?: return null
    val day = number(8, 2) ?: return null
    val hour = number(11, 2) ?: return null
    val minute = number(14, 2) ?: return null
    val second = number(17, 2) ?: return null
    if (month !in 1..12 || day !in 1..31 || hour >= 24 || minute >= 60 || second >= 61) return null
    var index = 19
    var millis = 0L
    if (isChar(index, '.')) {
        index++
        val start = index
        var scale = 100L
        while (index < bytes.size - 1 && bytes[index] - '0'.code in 0..9) {
            millis += (bytes[index] - '0'.code) * scale
            scale /= 10
            index++
        }
        if (index == start) return null
    }
    if (index != bytes.size - 1) return null
    val shifted = if (month <= 2) year - 1 else year
    val era = (if (shifted >= 0) shifted else shifted - 399) / 400
    val yearOfEra = shifted - era * 400
    val dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
    val dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    val days = era * 146_097 + dayOfEra - 719_468
    return ((days * 24 + hour) * 60 + minute) * 60_000 + second * 1000 + millis
}
