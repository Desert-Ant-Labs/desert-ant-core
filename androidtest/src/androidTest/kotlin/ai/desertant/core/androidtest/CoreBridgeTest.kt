package ai.desertant.core.androidtest

import ai.desertant.DesertAntNative
import ai.desertant.core.HostBridge
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
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
     * response comes back: the host's httpRequest callback is installed. Without
     * it every usage send on Android failed before leaving the device. The
     * Kotlin transport is checked on its own first, so a failure says which
     * layer broke.
     */
    @Test
    fun aPostFromTheSwiftCoreReachesTheServer() {
        // 127.0.0.1 explicitly: Android's getLoopbackAddress() is ::1, and the
        // requests below go to http://127.0.0.1.
        ServerSocket(0, 2, InetAddress.getByName("127.0.0.1")).use { server ->
            // Bounded, so a request that never arrives fails the test with its
            // error rather than leaving accept() and join() waiting forever.
            server.soTimeout = 10_000
            val url = "http://127.0.0.1:${server.localPort}/ingest"

            // The same request the Swift side sends, from Kotlin directly.
            val (direct, directRequest) = serveOnce(server)
            HostBridge.lastHttpRequestError = null
            val kotlinResult = HostBridge.httpRequest(
                "POST".toByteArray(), url.toByteArray(), """{"events":[]}""".toByteArray(),
                "application/json".toByteArray(), "Authorization: Bearer pk_test".toByteArray(),
            )
            direct.join(10_000)
            assertNotNull(
                "request seen: $directRequest | Kotlin error: " +
                    HostBridge.lastHttpRequestError?.stackTraceToString()?.lines()?.joinToString(" | ") { it.trim() },
                kotlinResult,
            )

            val (serving, request) = serveOnce(server)
            HostBridge.lastHttpRequestError = null
            var result = "error: post did not return within 30 s"
            thread { result = CoreBridge.post(DesertAntNative::class.java, url.toByteArray()) }.join(30_000)
            serving.join(10_000)

            // One line: Gradle's console drops a failure message after its first lines.
            assertEquals(
                "request seen: $request | Kotlin error: " +
                    HostBridge.lastHttpRequestError?.stackTraceToString()?.lines()?.joinToString(" | ") { it.trim() },
                "202 ok", result,
            )
            assertEquals("POST /ingest HTTP/1.1", request[1])  // after "accepted"
            assertEquals(listOf("Content-Type: application/json"), request.filter { it.startsWith("Content-Type:", ignoreCase = true) })
            assertEquals(listOf("Authorization: Bearer pk_test"), request.filter { it.startsWith("Authorization:", ignoreCase = true) })
            assertEquals("""{"events":[]}""", request.last())
        }
    }

    /**
     * Serve one request on [server], answering 202 "ok", and collect its request
     * line, headers and body. Failures are swallowed: an uncaught exception on
     * this thread would crash the test process and hide the assertion message.
     */
    private fun serveOnce(server: ServerSocket): Pair<Thread, List<String>> {
        val request = java.util.Collections.synchronizedList(mutableListOf<String>())
        val started = System.currentTimeMillis()
        val serving = thread {
            try {
                server.accept().use { socket ->
                    socket.soTimeout = 10_000
                    request += "accepted after ${System.currentTimeMillis() - started} ms"
                    val input = socket.getInputStream().bufferedReader()
                    // Recorded as read, so a request that stalls shows how far it got.
                    val head = generateSequence { input.readLine()?.also { request += it } }.takeWhile { it.isNotEmpty() }.toList()
                    val length = head.first { it.startsWith("Content-Length:", ignoreCase = true) }
                        .substringAfter(':').trim().toInt()
                    val body = CharArray(length).also {
                        var read = 0
                        while (read < length) {
                            val n = input.read(it, read, length - read)
                            if (n < 0) break
                            read += n
                        }
                    }
                    request += String(body)
                    socket.getOutputStream().write("HTTP/1.1 202 Accepted\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".toByteArray())
                }
            } catch (_: Exception) {
            }
        }
        return serving to request
    }
}
