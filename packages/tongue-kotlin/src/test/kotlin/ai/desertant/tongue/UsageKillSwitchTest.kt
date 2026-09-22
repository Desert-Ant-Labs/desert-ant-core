package ai.desertant.tongue

import ai.desertant.tongue.usage.UsageStorage
import ai.desertant.tongue.usage.UsageTurnstile
import ai.desertant.tongue.usage.readEnvironment
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.util.concurrent.atomic.AtomicInteger
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * `DAL_USAGE_DISABLED` as a JVM system property, the form a caller that cannot
 * set the environment uses. The Gradle test task sets the environment variable
 * for every test, and the environment wins, so this blanks the environment for
 * its duration; otherwise the switch would be on before the test touched it and
 * the property would prove nothing.
 */
class UsageKillSwitchTest {
    private class CountingStorage : UsageStorage {
        val touches = AtomicInteger()
        private val values = mutableMapOf<String, String>()
        override fun get(key: String): String? { touches.incrementAndGet(); return values[key] }
        override fun set(key: String, value: String) { touches.incrementAndGet(); values[key] = value }
    }

    @Test
    fun thePropertySwitchStopsTheRequestAndTheStore() {
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
        val previousSwitch = System.getProperty("DAL_USAGE_DISABLED")
        readEnvironment = { null }
        System.setProperty("DAL_INGEST_ENDPOINT", "http://127.0.0.1:${server.address.port}/api/v1/ingest")
        try {
            // Control: with the switch off, the same path stores and posts. Without
            // it, a dead endpoint would pass the assertions below as well.
            System.clearProperty("DAL_USAGE_DISABLED")
            val liveStorage = CountingStorage()
            val live = assertNotNull(UsageTurnstile.create(null, liveStorage))
            live.record()
            assertTrue(live.flushTelemetry())
            assertEquals(1, requests.get(), "the control flush did not reach the server")
            assertTrue(liveStorage.touches.get() > 0, "the control client never used its store")

            System.setProperty("DAL_USAGE_DISABLED", "1")
            val offStorage = CountingStorage()
            assertNull(UsageTurnstile.create(null, offStorage), "a client was built with the switch on")
            assertEquals(0, offStorage.touches.get(), "the switch on still touched the store")

            val tongue = Tongue.bundled()
            tongue.detect("kann ich das haben")
            assertTrue(tongue.flushTelemetry(), "a switched-off flush has nothing to fail")
            assertEquals(1, requests.get(), "the switch on still posted")
        } finally {
            readEnvironment = previousEnvironment
            if (previousEndpoint == null) System.clearProperty("DAL_INGEST_ENDPOINT")
            else System.setProperty("DAL_INGEST_ENDPOINT", previousEndpoint)
            if (previousSwitch == null) System.clearProperty("DAL_USAGE_DISABLED")
            else System.setProperty("DAL_USAGE_DISABLED", previousSwitch)
            server.stop(0)
        }
    }
}
