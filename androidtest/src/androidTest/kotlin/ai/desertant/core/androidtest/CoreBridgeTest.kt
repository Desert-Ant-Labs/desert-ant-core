package ai.desertant.core.androidtest

import ai.desertant.DesertAntNative
import ai.desertant.core.HostBridge
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import java.net.InetAddress
import java.net.ServerSocket
import kotlin.concurrent.thread

/**
 * On-device (Tier 2a) integration test: drives the Swift core's host-backed
 * paths through JNI with the real Android host (java.util.regex + the platform
 * JSON parser installed via DesertAntNative, the host class every SDK installs).
 * An empty result means every check passed on the device/emulator.
 *
 * The bridge installs once per process, so every test passes the same class.
 */
@RunWith(AndroidJUnit4::class)
class CoreBridgeTest {
    @Test
    fun hostBackedPathsWork() {
        assertEquals("", CoreBridge.runChecks(DesertAntNative::class.java))
    }

    /**
     * The facts Kotlin reads reach the context the Swift client sends, and the
     * Kotlin opt-out reaches the Swift one: with it on, not even osName goes,
     * which emptying the facts alone would still have sent.
     */
    @Test
    fun theUsageContextCarriesTheDeviceFactsAndHonoursTheOptOut() {
        HostBridge.attach(InstrumentationRegistry.getInstrumentation().targetContext)

        val context = CoreBridge.usageContext(DesertAntNative::class.java).lines()
            .filter { it.isNotEmpty() }
            .associate { it.substringBefore('=') to it.substringAfter('=') }
        assertEquals("Android", context["osName"])
        for (key in listOf("osVersion", "deviceModel", "formFactor", "locale")) {
            assertFalse("no $key in $context", context[key].isNullOrEmpty())
        }

        HostBridge.sendsDeviceContext = false
        try {
            assertEquals("", CoreBridge.usageContext(DesertAntNative::class.java))
        } finally {
            HostBridge.sendsDeviceContext = true
        }
    }

    /**
     * A POST from the Swift core reaches a server, headers included, and its
     * response comes back: the host's httpRequest callback is installed. Without it every usage send
     * on Android failed before leaving the device.
     */
    @Test
    fun aPostFromTheSwiftCoreReachesTheServer() {
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
            // Bounded, so a POST that never arrives fails the test with its
            // error rather than leaving accept() and join() waiting forever.
            server.soTimeout = 10_000
            var request = listOf<String>()
            val serving = thread {
                server.accept().use { socket ->
                    socket.soTimeout = 10_000
                    val input = socket.getInputStream().bufferedReader()
                    val head = generateSequence { input.readLine() }.takeWhile { it.isNotEmpty() }.toList()
                    val length = head.first { it.startsWith("Content-Length:", ignoreCase = true) }
                        .substringAfter(':').trim().toInt()
                    val body = CharArray(length).also { var read = 0; while (read < length) read += input.read(it, read, length - read) }
                    request = head + String(body)
                    socket.getOutputStream().write("HTTP/1.1 202 Accepted\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".toByteArray())
                }
            }

            var result = "error: post did not return within 30 s"
            thread {
                result = CoreBridge.post(DesertAntNative::class.java, "http://127.0.0.1:${server.localPort}/ingest".toByteArray())
            }.join(30_000)
            assertEquals("202 ok", result)
            serving.join(10_000)

            assertEquals("POST /ingest HTTP/1.1", request.first())
            assertEquals(listOf("Content-Type: application/json"), request.filter { it.startsWith("Content-Type:", ignoreCase = true) })
            assertEquals(listOf("Authorization: Bearer pk_test"), request.filter { it.startsWith("Authorization:", ignoreCase = true) })
            assertEquals("""{"events":[]}""", request.last())
        }
    }
}
