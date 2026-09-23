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
internal const val INGEST_ENDPOINT: String = "https://events.desertant.com/api/v1/ingest"

/**
 * The ingest endpoint for this process. Core lets a host override it for tests
 * and local capture (`hostProvidedIngestEndpoint`), and this reads the same
 * variable; the system property is the same override for a caller that cannot
 * set the environment.
 */
internal fun ingestEndpoint(): String =
    setting("DAL_INGEST_ENDPOINT") ?: INGEST_ENDPOINT

/**
 * The publishable API key for this process, or null. A key set in code
 * (`DesertAnt.apiKey`) wins, matching core's `hostProvidedApiKey()`; otherwise
 * it is read from the environment as core does, then from the same-named system
 * property. Trimmed: a key read from a secret file often ends in a newline, which
 * the body tolerated but `setRequestProperty` rejects, dropping the POST.
 */
internal fun apiKey(): String? =
    ai.desertant.tongue.DesertAnt.apiKey?.trim()?.takeIf { it.isNotEmpty() }
        ?: setting("DAL_API_KEY")?.trim()?.takeIf { it.isNotEmpty() }

/**
 * A host-provided device id, or null. Core's `hostProvidedDeviceId()` reads the
 * same variable, and when set it replaces the persisted per-install id: a server
 * that knows its own device identity names it rather than being counted anew
 * per process.
 */
internal fun hostProvidedDeviceId(): String? = setting("DAL_DEVICE_ID")

/**
 * How this port reads the process environment. A seam for tests only: the Gradle
 * test task sets `DAL_USAGE_DISABLED` in the environment, and the environment
 * wins, so without it the system property path could never be exercised.
 */
internal var readEnvironment: (String) -> String? = System::getenv

/** An environment variable, then the same-named system property, then null. */
internal fun setting(name: String): String? =
    readEnvironment(name)?.takeIf { it.isNotEmpty() }
        ?: System.getProperty(name)?.takeIf { it.isNotEmpty() }

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

/**
 * The platform tag this build reports. The endpoint accepts exactly
 * ios|android|web|server and rejects anything else with a 400, which drops the
 * event silently: a JVM is a `server`, not a `jvm`.
 */
internal fun defaultPlatform(): String = if (isAndroid()) "android" else "server"

/**
 * A send in flight. `await` blocks until the POST has finished or `deadlineNanos`
 * (a `System.nanoTime()` value) passes, so a short-lived caller can be sure the
 * request left the process before it exits. A send still running at the deadline
 * is left to finish on the sender: it may yet land.
 */
internal fun interface SendHandle {
    fun await(deadlineNanos: Long)
}

/**
 * How long a flush waits for its sends, all of them together. The connection's
 * own timeouts bound one send to about 10 s, and a flush may await two, which on
 * Android's main thread is an ANR; the Node port bounds each send to 5 s too.
 */
internal const val FLUSH_WAIT_MS: Long = 5_000L

/** Await with a deadline `FLUSH_WAIT_MS` from now. */
internal fun SendHandle.await() = await(System.nanoTime() + FLUSH_WAIT_MS * 1_000_000L)

/** Await every handle against one shared deadline, so two sends cannot wait 2x. */
internal fun List<SendHandle>.awaitAll() {
    val deadline = System.nanoTime() + FLUSH_WAIT_MS * 1_000_000L
    forEach { it.await(deadline) }
}

/**
 * A `send` that POSTs the serialized body, fire and forget unless awaited.
 *
 * The key rides an `Authorization` header, not the body: every transport this
 * port runs on sets request headers (Android's `HttpURLConnection` included,
 * unlike core's Android host bridge), and the endpoint prefers the header.
 */
internal fun makeSend(endpoint: String = INGEST_ENDPOINT, bearerKey: String? = null): (IngestBody) -> SendHandle? = { body ->
    val json = runCatching { buildBody(body) }.getOrNull()
    if (json == null) {
        null
    } else {
        runCatching {
            sender.submit {
                runCatching {
                    val connection = URL(endpoint).openConnection() as HttpURLConnection
                    connection.requestMethod = "POST"
                    connection.doOutput = true
                    connection.connectTimeout = 5_000
                    connection.readTimeout = 5_000
                    connection.setRequestProperty("Content-Type", "application/json")
                    if (bearerKey != null) {
                        connection.setRequestProperty("Authorization", "Bearer $bearerKey")
                    }
                    connection.outputStream.use { it.write(json.toByteArray(Charsets.UTF_8)) }
                    connection.responseCode // the request is not sent until this is read
                    connection.disconnect()
                }
            }
        }.getOrNull()?.let { future -> SendHandle { deadline -> awaitFuture(future, deadline) } }
    }
}

/** Wait for the POST until the deadline. A cancellation request is re-flagged rather than swallowed. */
private fun awaitFuture(future: java.util.concurrent.Future<*>, deadlineNanos: Long) {
    try {
        future.get(maxOf(0L, deadlineNanos - System.nanoTime()), java.util.concurrent.TimeUnit.NANOSECONDS)
    } catch (_: java.util.concurrent.TimeoutException) {
        // Not cancelled: the POST keeps running on the sender and may still land.
    } catch (interrupted: InterruptedException) {
        Thread.currentThread().interrupt()
    } catch (_: java.util.concurrent.ExecutionException) {
        // The body already swallows its own failures; this cannot surface one.
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

/**
 * Whether usage reporting is switched off, right now: `DesertAnt.usageDisabled`
 * set in code, or `DAL_USAGE_DISABLED` in the environment or as a system
 * property, under `flagIsSet`. Read per call, so an app can hold it on until its
 * user consents and clear it then. See packages/tongue-node/USAGE.md.
 */
internal fun usageDisabled(): Boolean =
    ai.desertant.tongue.DesertAnt.usageDisabled ||
        flagIsSet(readEnvironment("DAL_USAGE_DISABLED")) ||
        flagIsSet(System.getProperty("DAL_USAGE_DISABLED"))

/**
 * Build a client wired to the shared endpoint, the system clock, a POST transport,
 * the best available storage and the default device context. Mirrors core's
 * `makeClient`.
 */
internal fun makeClient(
    context: Any? = null,
    sdkVersion: String,
    storage: UsageStorage = defaultStorage(context),
    send: ((IngestBody) -> SendHandle?)? = null,
    now: () -> Long = System::currentTimeMillis,
): UsageClient {
    val appId = defaultAppIdentifier(context)
    val key = apiKey()
    val namespace = key ?: appId
    val hostDevice = hostProvidedDeviceId()
    // A host id equal to the stored one is still this device's own, as core
    // and the Node port count it.
    val stored = if (hostDevice != null) storage.storedDeviceId() else null
    val device = hostDevice ?: storage.persistentDeviceId()
    val platform = defaultPlatform()
    return UsageClient(
        ClientDeps(
            deviceId = device,
            appId = appId,
            platform = platform,
            sdkVersion = sdkVersion,
            context = defaultContextProvider(
                platform,
                deviceIdSupplied = hostDevice != null && hostDevice != stored,
                facts = runCatching { detectDeviceFacts(context) }.getOrDefault(DeviceFacts()),
            ),
            now = now,
            loadState = { storage.loadState(namespace, device) },
            saveState = { storage.saveState(it, namespace, device) },
            // The key is only known here, so the real transport is built here too;
            // a caller-supplied one still wins (tests).
            send = send ?: makeSend(ingestEndpoint(), key),
        ),
    )
}
