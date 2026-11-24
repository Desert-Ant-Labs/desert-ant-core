package ai.desertant.tongue.license

import ai.desertant.tongue.DesertAnt
import java.net.HttpURLConnection
import java.net.URI
import java.util.concurrent.Executor
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ThreadFactory
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

// A full batch answer is 100 licenses, about 50 KB.
private const val MAX_ANSWER_BYTES = 1024 * 1024

internal fun trimmedKey(key: String?): String? = key?.trim()?.takeIf { it.isNotEmpty() }

internal fun httpPost(url: String, body: ByteArray, apiKey: String?): HttpReply? {
    var connection: HttpURLConnection? = null
    return try {
        connection = URI(url).toURL().openConnection() as HttpURLConnection
        connection.requestMethod = "POST"
        connection.connectTimeout = LICENSE_TIMEOUT_MS
        connection.readTimeout = LICENSE_TIMEOUT_MS
        // A redirect would carry the key to another host.
        connection.instanceFollowRedirects = false
        connection.setRequestProperty("Content-Type", "application/json")
        if (apiKey != null) connection.setRequestProperty("Authorization", "Bearer $apiKey")
        connection.doOutput = true
        connection.setFixedLengthStreamingMode(body.size)
        connection.outputStream.use { it.write(body) }
        val status = connection.responseCode
        val stream = if (status >= 400) connection.errorStream else connection.inputStream
        val answer = stream?.use { readAtMost(it, MAX_ANSWER_BYTES) } ?: ByteArray(0)
        if (answer.size > MAX_ANSWER_BYTES) null else HttpReply(status, answer, connection.getHeaderField("Retry-After"))
    } catch (_: Throwable) {
        null
    } finally {
        connection?.disconnect()
    }
}

/** Up to one byte more than [limit], so the caller can tell a longer answer. */
internal fun readAtMost(stream: java.io.InputStream, limit: Int): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    val chunk = ByteArray(8192)
    while (out.size() <= limit) {
        val count = stream.read(chunk, 0, minOf(chunk.size, limit + 1 - out.size()))
        if (count < 0) break
        out.write(chunk, 0, count)
    }
    return out.toByteArray()
}

/** What the process knows about its host: the Android store and package, the key, the endpoint. */
internal object LicenseHost {
    @Volatile private var androidStore: LicenseStore? = null
    @Volatile private var applicationId: String? = null
    private val fallbackStore: LicenseStore by lazy {
        if (isAndroid()) MemoryStore() else FileStore(stateDirectory(::setting, System.getProperty("user.home")), ::warn)
    }
    val platform: String by lazy { if (isAndroid()) "android" else "server" }

    // Only unset values are filled, as the core's HostBridge.attach does, so the next load after the first unlock fills the store.
    @Synchronized
    fun attach(context: Any?) {
        if (context == null) return
        if (applicationId == null) applicationId = AndroidPreferencesStore.packageName(context)
        if (androidStore == null) androidStore = AndroidPreferencesStore.forContext(context)
    }

    fun store(): LicenseStore = androidStore ?: fallbackStore

    /** False on Android until a load passed a Context: an install id made now would be new in every process. */
    fun keepsLicenses(): Boolean = platform != "android" || androidStore != null

    fun warn(message: String) {
        java.util.logging.Logger.getLogger("ai.desertant.tongue").warning(message)
    }

    fun identity(): LicenseIdentity = LicenseIdentity(
        appId = setting("DAL_APP_ID") ?: applicationId?.takeIf { it.isNotEmpty() } ?: if (platform == "server") "java" else "unknown",
        apiKey = trimmedKey(DesertAnt.currentApiKey) ?: trimmedKey(coreApiKey()),
        platform = platform,
    )

    fun endpoint(): String = setting("DAL_LICENSE_ENDPOINT") ?: DEFAULT_LICENSE_ENDPOINT

    fun setting(name: String): String? = try {
        System.getenv(name)?.takeIf { it.isNotEmpty() }
    } catch (_: SecurityException) {
        null
    }

    // The core's own consumer rule keeps this accessor by name, so it is there in a minified app too.
    private val coreApiKeyAccessor: java.lang.reflect.Method? by lazy {
        if (!isAndroid()) {
            null
        } else {
            try {
                Class.forName("ai.desertant.DesertAntNative").getMethod("apiKey")
            } catch (_: Throwable) {
                null
            }
        }
    }

    fun coreIsPresent(): Boolean = coreApiKeyAccessor != null

    private fun coreApiKey(): String? = try {
        (coreApiKeyAccessor?.invoke(null) as? ByteArray)?.toString(Charsets.UTF_8)
    } catch (_: Throwable) {
        null
    }
}

internal class LicenseRuntime(
    private val deps: LicenseDeps,
    private val submit: (Executor, Runnable) -> Unit = { executor, work -> executor.execute(work) },
) {
    private val inFlight = InFlight()
    private val timer = ScheduledThreadPoolExecutor(1, daemonThreads("tongue-license"))
    private val senders = ThreadPoolExecutor(
        1, 1, 30, TimeUnit.SECONDS, LinkedBlockingQueue(), daemonThreads("tongue-device-license"),
    ).apply { allowCoreThreadTimeOut(true) }
    private val install = InstallLicenseClient(deps) { delay, work -> later(delay) { track(timer, work) } }
    val devices = DeviceLicenseClient(deps, { work -> track(senders, work) }, ::later)

    fun modelLoaded() {
        track(timer) { install.modelLoaded() }
    }

    fun modelRan(deviceId: String?) = devices.modelRan(deviceId)

    /** Waits for the requests in flight and sends the queued device licenses. No request starts after 10 seconds. */
    fun flush(): Boolean {
        val ends = deps.now() + DEVICE_LICENSE_FLUSH_MS
        val giveUp = System.nanoTime() + (DEVICE_LICENSE_FLUSH_MS + LICENSE_TIMEOUT_MS) * 1_000_000
        // Set before the wait, so a send that already runs stops at its next request too.
        devices.limitSends(ends)
        try {
            inFlight.awaitNone(giveUp)
            devices.pump(force = true)
            inFlight.awaitNone(giveUp)
            return devices.pending == 0
        } finally {
            devices.endLimit()
        }
    }

    private fun later(delayMs: Long, work: () -> Unit) {
        try {
            timer.schedule({ guarded(work) }, maxOf(delayMs, 0), TimeUnit.MILLISECONDS)
        } catch (_: Throwable) {
        }
    }

    // Counted before this returns, so a flush right after a model load waits for the work. False when the work cannot start.
    private fun track(executor: Executor, work: () -> Unit): Boolean {
        inFlight.add(1)
        try {
            submit(executor) {
                try {
                    guarded(work)
                } finally {
                    inFlight.add(-1)
                }
            }
            return true
        } catch (_: Throwable) {
            inFlight.add(-1)
            return false
        }
    }

    private fun guarded(work: () -> Unit) {
        try {
            work()
        } catch (_: Throwable) {
        }
    }

    private class InFlight {
        private val lock = ReentrantLock()
        private val none = lock.newCondition()
        private var count = 0

        fun add(change: Int) = lock.withLock {
            count += change
            if (count == 0) none.signalAll()
        }

        fun awaitNone(deadlineNanos: Long) = lock.withLock {
            while (count > 0) {
                val left = deadlineNanos - System.nanoTime()
                if (left <= 0) break
                none.awaitNanos(left)
            }
        }
    }

    private companion object {
        // Daemon threads: a request in flight or a retry that waits never keeps the JVM alive.
        fun daemonThreads(name: String) = ThreadFactory { work ->
            Thread(work, name).apply {
                isDaemon = true
                priority = Thread.MIN_PRIORITY
            }
        }
    }
}

/** The process-wide entry points Tongue calls. They never throw and never wait for a request. */
internal object Licensing {
    @Volatile private var installed: LicenseRuntime? = null

    private fun runtime(): LicenseRuntime = installed ?: synchronized(this) {
        installed ?: LicenseRuntime(
            LicenseDeps(
                store = LicenseHost::store,
                identity = LicenseHost::identity,
                secret = { DesertAnt.currentDeviceIdSecret },
                endpoint = LicenseHost::endpoint,
                keepsLicenses = LicenseHost::keepsLicenses,
                coreIsPresent = LicenseHost::coreIsPresent,
            ),
        ).also { installed = it }
    }

    /** Replaces the process-wide runtime, for tests. Null restores the default one on the next call. */
    fun use(runtime: LicenseRuntime?) {
        installed = runtime
    }

    fun modelLoaded(context: Any?) {
        try {
            LicenseHost.attach(context)
            runtime().modelLoaded()
        } catch (_: Throwable) {
        }
    }

    fun modelRan(deviceId: String?) {
        try {
            runtime().modelRan(deviceId)
        } catch (_: Throwable) {
        }
    }

    fun flush(): Boolean = try {
        runtime().flush()
    } catch (_: InterruptedException) {
        Thread.currentThread().interrupt()
        false
    } catch (_: Throwable) {
        false
    }
}
