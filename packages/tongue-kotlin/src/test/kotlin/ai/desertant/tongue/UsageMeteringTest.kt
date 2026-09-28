package ai.desertant.tongue

import ai.desertant.tongue.usage.InMemoryStorage
import ai.desertant.tongue.usage.UsageStorage
import ai.desertant.tongue.usage.UsageTurnstile
import ai.desertant.tongue.usage.readEnvironment
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Usage always posts; the process-wide settings it changes are safe only because Gradle runs these classes serially. */
class UsageMeteringTest {
    @Test
    fun aDetectionAlwaysPostsToTheIngest() = withCaptureServer { requests ->
        // A throwaway usage store: the JVM's own is shared by every keyless Tongue app for this user.
        val tongue = Tongue.bundled(null, InMemoryStorage())
        tongue.detect("kann ich das haben")
        assertTrue(tongue.flushTelemetry())
        assertEquals(1, requests.get(), "the detection did not post")
    }

    /** A store that fails once must not stop reporting for the life of the turnstile. */
    @Test
    fun aClientBuildThatFailsOnceIsTriedAgain() = withCaptureServer { requests ->
        val values = mutableMapOf<String, String>()
        var failures = 1
        val storage = object : UsageStorage {
            override fun get(key: String): String? {
                if (failures > 0) { failures -= 1; throw IllegalStateException("transient") }
                return values[key]
            }
            override fun set(key: String, value: String) { values[key] = value }
        }
        val turnstile = UsageTurnstile.create(null, storage)
        turnstile.record()
        assertTrue(turnstile.flushTelemetry())
        assertEquals(0, requests.get(), "the failed build posted")
        turnstile.record()
        assertTrue(turnstile.flushTelemetry())
        assertEquals(1, requests.get(), "one failed build stopped reporting for good")
    }

    private fun withCaptureServer(body: (AtomicInteger) -> Unit) {
        val requests = AtomicInteger()
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        server.createContext("/api/v1/ingest") { exchange ->
            requests.incrementAndGet()
            exchange.requestBody.readBytes()
            exchange.sendResponseHeaders(202, -1)
            exchange.close()
        }
        server.start()
        val previousEnvironment = readEnvironment
        val previousEndpoint = System.getProperty("DAL_INGEST_ENDPOINT")
        readEnvironment = { null }
        System.setProperty("DAL_INGEST_ENDPOINT", "http://127.0.0.1:${server.address.port}/api/v1/ingest")
        try {
            body(requests)
        } finally {
            readEnvironment = previousEnvironment
            if (previousEndpoint == null) System.clearProperty("DAL_INGEST_ENDPOINT")
            else System.setProperty("DAL_INGEST_ENDPOINT", previousEndpoint)
            server.stop(0)
        }
    }
}
