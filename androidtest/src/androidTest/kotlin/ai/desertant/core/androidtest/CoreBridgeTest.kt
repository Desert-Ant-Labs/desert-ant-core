package ai.desertant.core.androidtest

import ai.desertant.DesertAntNative
import ai.desertant.core.HostBridge
import ai.desertant.core.HostBridgeTestHooks
import ai.desertant.tongue.Tongue
import android.content.Context
import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
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
     * A POST from the Swift core reaches a server, headers included, and its
     * response comes back: the host's httpRequest callback is installed. Without
     * it every license request on Android failed before leaving the device. The
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
            lastHttpRequestError = null
            val kotlinResult = HostBridge.httpRequest(
                "POST".toByteArray(), url.toByteArray(), """{"events":[]}""".toByteArray(),
                "application/json".toByteArray(), "Authorization: Bearer pk_test".toByteArray(),
            )
            direct.join(10_000)
            assertNotNull(
                "request seen: $directRequest | Kotlin error: " +
                    lastHttpRequestError?.stackTraceToString()?.lines()?.joinToString(" | ") { it.trim() },
                kotlinResult,
            )

            val (serving, request) = serveOnce(server)
            lastHttpRequestError = null
            var result = "error: post did not return within 30 s"
            thread { result = CoreBridge.post(DesertAntNative::class.java, url.toByteArray()) }.join(30_000)
            serving.join(10_000)

            // One line: Gradle's console drops a failure message after its first lines.
            assertEquals(
                "request seen: $request | Kotlin error: " +
                    lastHttpRequestError?.stackTraceToString()?.lines()?.joinToString(" | ") { it.trim() },
                "202 ok", result,
            )
            assertEquals("POST /ingest HTTP/1.1", request[1])  // after "accepted"
            assertEquals(listOf("Content-Type: application/json"), request.filter { it.startsWith("Content-Type:", ignoreCase = true) })
            assertEquals(listOf("Authorization: Bearer pk_test"), request.filter { it.startsWith("Authorization:", ignoreCase = true) })
            assertEquals("""{"events":[]}""", request.last())
        }
    }

    // Every vector token gets the verdict the contract gives it: the host's verifyLicense is installed and Conscrypt agrees.
    @Test
    fun theSwiftCoreVerifiesLicenseTokensThroughTheHost() {
        val assets = InstrumentationRegistry.getInstrumentation().context.assets
        val vectors = Json.parseToJsonElement(assets.open("license_vectors.json").use { it.readBytes().decodeToString() }).jsonObject
        val keys = vectors["keys"]!!.jsonArray.joinToString("\n") {
            "${it.jsonObject["kid"]!!.jsonPrimitive.content}=${it.jsonObject["publicKeyX963"]!!.jsonPrimitive.content}"
        }
        val verdicts = vectors["tokens"]!!.jsonArray.map { it.jsonObject }.associate { vector ->
            val token = vector["token"]!!.jsonPrimitive.content
            vector["name"]!!.jsonPrimitive.content to
                CoreBridge.verifyLicense(DesertAntNative::class.java, token.toByteArray(), keys.toByteArray())
        }
        val expected = vectors["tokens"]!!.jsonArray.map { it.jsonObject }.associate {
            it["name"]!!.jsonPrimitive.content to (it["expect"]!!.jsonPrimitive.content == "valid")
        }
        assertEquals(expected, verdicts)
    }

    /**
     * The exception behind the last failed HostBridge.httpRequest. It only
     * feeds failure messages. Internal to :core, so it comes through core's
     * debug-only HostBridgeTestHooks.
     */
    private var lastHttpRequestError: Throwable?
        get() = HostBridgeTestHooks.lastHttpRequestError
        set(value) {
            HostBridgeTestHooks.lastHttpRequestError = value
        }

    /**
     * Serve one request on [server], answering 202 "ok" or [response], and collect its request
     * line, headers and body. Failures are swallowed: an uncaught exception on
     * this thread would crash the test process and hide the assertion message.
     */
    private fun serveOnce(
        server: ServerSocket,
        response: String = "HTTP/1.1 202 Accepted\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
    ): Pair<Thread, List<String>> {
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
                    socket.getOutputStream().write(response.toByteArray())
                }
            } catch (_: Exception) {
            }
        }
        return serving to request
    }

    // Tongue reaches SharedPreferences by reflection, keeps the install id where the core's models keep theirs, and asks with it.
    @Test
    fun tongueKeepsItsInstallIdInTheSharedStoreAndAsksWithIt() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val store = context.getSharedPreferences("desert-ant", Context.MODE_PRIVATE)
        // No core model is loaded in this process, so only Tongue can write the id.
        assertNull(HostBridge.preferences)
        // An id or a Tongue license from an earlier run would leave nothing to write or to ask.
        val cleared = store.edit().remove(INSTALL_ID_KEY)
        store.all.keys.filter { it.startsWith("ai.desertant.tongue.license.") }.forEach { cleared.remove(it) }
        assertTrue(cleared.commit())
        val endpointBefore = Os.getenv("DAL_LICENSE_ENDPOINT")
        ServerSocket(0, 2, InetAddress.getByName("127.0.0.1")).use { server ->
            // The core is in this app, so Tongue first waits 10 seconds for the core's id.
            server.soTimeout = 20_000
            try {
                // Set here too, so a run without the runner's argument never asks the license server.
                Os.setenv("DAL_LICENSE_ENDPOINT", "http://127.0.0.1:${server.localPort}/api/v1", true)
                // A refusal, so Tongue does not ask again after the endpoint is restored.
                val refusal = """{"error":"test_refusal"}"""
                val (serving, request) = serveOnce(
                    server,
                    "HTTP/1.1 422 Unprocessable Entity\r\nContent-Type: application/json\r\nContent-Length: ${refusal.length}\r\nConnection: close\r\n\r\n$refusal",
                )
                Tongue.bundled(context)
                serving.join(25_000)
                val installId = store.getString(INSTALL_ID_KEY, null)
                assertFalse("request seen: $request", installId.isNullOrEmpty())
                assertEquals("request seen: $request", "POST /api/v1/license HTTP/1.1", request.getOrNull(1))
                assertTrue("request seen: $request", "\"installId\":\"$installId\"" in request.last())
                assertTrue("request seen: $request", "\"model\":\"tongue\"" in request.last())
            } finally {
                if (endpointBefore == null) Os.unsetenv("DAL_LICENSE_ENDPOINT") else Os.setenv("DAL_LICENSE_ENDPOINT", endpointBefore, true)
            }
        }
    }

    private companion object {
        const val INSTALL_ID_KEY = "ai.desertant.usage.deviceId"
    }
}
