package ai.desertant.tongue.usage

import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory

/**
 * Time, identity and the POST transport — the pieces core keeps in
 * `Identity.swift` and `Transport.swift`.
 *
 * `HttpURLConnection` rather than a client library: the jar must stay
 * free of declared dependencies, and it exists on every JVM and Android level this SDK
 * supports.
 */

/** The shared ingest endpoint. Every SDK reports to the same place. */
internal const val INGEST_ENDPOINT: String = "https://platform.desertant.ai/api/v1/ingest"

/**
 * Format epoch milliseconds as `2024-01-02T03:04:05.678Z`.
 *
 * Hand-formatted from a UTC calendar rather than `java.time`: `Instant` and
 * `DateTimeFormatter` need API 26 without desugaring, and this SDK supports
 * older Android. Matches core's `iso8601`, which hand-formats for the same
 * reason (no Foundation on its Android target).
 */
internal fun iso8601(epochMs: Long): String {
    val calendar = java.util.Calendar.getInstance(TimeZone.getTimeZone("UTC"), Locale.US)
    calendar.timeInMillis = epochMs
    return String.format(
        Locale.US,
        "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
        calendar.get(java.util.Calendar.YEAR),
        calendar.get(java.util.Calendar.MONTH) + 1,
        calendar.get(java.util.Calendar.DAY_OF_MONTH),
        calendar.get(java.util.Calendar.HOUR_OF_DAY),
        calendar.get(java.util.Calendar.MINUTE),
        calendar.get(java.util.Calendar.SECOND),
        calendar.get(java.util.Calendar.MILLISECOND),
    )
}

/**
 * One daemon thread, shared. A send must never block a detection and must never
 * keep a JVM alive: a short-lived CLI that detects once should exit immediately,
 * not linger on a non-daemon pool.
 */
private val sender = Executors.newSingleThreadExecutor(
    ThreadFactory { runnable ->
        Thread(runnable, "tongue-usage").apply { isDaemon = true; priority = Thread.MIN_PRIORITY }
    },
)

/** A `send` that POSTs the serialized body, fire and forget. */
internal fun makeSend(endpoint: String = INGEST_ENDPOINT): (IngestBody) -> Unit = { body ->
    val json = runCatching { buildBody(body) }.getOrNull()
    if (json != null) {
        runCatching {
            sender.execute {
                runCatching {
                    val connection = URL(endpoint).openConnection() as HttpURLConnection
                    connection.requestMethod = "POST"
                    connection.doOutput = true
                    connection.connectTimeout = 5_000
                    connection.readTimeout = 5_000
                    connection.setRequestProperty("Content-Type", "application/json")
                    connection.outputStream.use { it.write(json.toByteArray(Charsets.UTF_8)) }
                    connection.responseCode // the request is not sent until this is read
                    connection.disconnect()
                }
            }
        }
    }
}

/**
 * The application identity used for keyless attribution: core sends the bundle id
 * on Apple and the package name on Android. Reflectively on Android (see
 * Storage.kt for why), otherwise the main class or process name.
 */
internal fun defaultAppIdentifier(context: Any? = null): String {
    if (context != null) {
        val packageName = runCatching {
            context.javaClass.getMethod("getPackageName").invoke(context) as? String
        }.getOrNull()
        if (!packageName.isNullOrEmpty()) return packageName
    }
    System.getenv("DAL_APP_ID")?.takeIf { it.isNotEmpty() }?.let { return it }
    return System.getProperty("java.vm.name")?.takeIf { it.isNotEmpty() } ?: "unknown"
}

/** Whether usage reporting is switched off for this process. See docs/USAGE.md. */
internal fun usageDisabled(): Boolean {
    val value = System.getenv("DAL_USAGE_DISABLED") ?: System.getProperty("DAL_USAGE_DISABLED")
    return !value.isNullOrEmpty() && value != "0"
}

/**
 * Build a client wired to the shared endpoint, the system clock, a POST transport
 * and the best available storage. Mirrors core's `makeClient`.
 */
internal fun makeClient(
    context: Any? = null,
    sdkVersion: String,
    storage: UsageStorage = defaultStorage(context),
    send: (IngestBody) -> Unit = makeSend(),
    now: () -> Long = System::currentTimeMillis,
): UsageClient {
    val appId = defaultAppIdentifier(context)
    val key = System.getenv("DAL_API_KEY")?.takeIf { it.isNotEmpty() }
    val namespace = key ?: appId
    val device = storage.persistentDeviceId()
    return UsageClient(
        ClientDeps(
            deviceId = device,
            key = key,
            appId = appId,
            platform = if (isAndroid()) "android" else "jvm",
            sdkVersion = sdkVersion,
            now = now,
            loadState = { storage.loadState(namespace, device) },
            saveState = { storage.saveState(it, namespace, device) },
            send = send,
        ),
    )
}
