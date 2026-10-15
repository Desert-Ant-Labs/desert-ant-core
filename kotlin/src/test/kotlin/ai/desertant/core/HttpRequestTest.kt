package ai.desertant.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.nio.ByteBuffer
import kotlin.concurrent.thread

class HttpRequestTest {
    // A one-shot HTTP/1.1 server on a plain socket: the Android unit-test
    // classpath has no com.sun.net.httpserver.
    private val server = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
    private val url get() = "http://127.0.0.1:${server.localPort}/ingest"
    private var request = ""

    @After fun stop() = server.close()

    private fun serve(status: Int, reply: String, headers: String = "") = thread {
        server.accept().use { socket ->
            val input = socket.getInputStream().bufferedReader()
            val head = generateSequence { input.readLine() }.takeWhile { it.isNotEmpty() }.toList()
            val length = head.firstOrNull { it.startsWith("Content-Length:", ignoreCase = true) }
                ?.substringAfter(':')?.trim()?.toInt() ?: 0
            val body = CharArray(length).also { var read = 0; while (read < length) read += input.read(it, read, length - read) }
            request = (head + String(body)).joinToString("\n")
            val bytes = reply.toByteArray()
            socket.getOutputStream().write(
                "HTTP/1.1 $status X\r\n${headers}Content-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray() + bytes,
            )
        }
    }

    /** Status, length, body: the layout Swift's HTTPClient reads. */
    private fun decode(result: ByteArray): Pair<Int, String> {
        val buffer = ByteBuffer.wrap(result)
        val status = buffer.int
        val body = ByteArray(buffer.int).also { buffer.get(it) }
        return status to body.decodeToString()
    }

    private fun retryAfter(result: ByteArray): String {
        val buffer = ByteBuffer.wrap(result)
        buffer.position(8 + buffer.getInt(4))
        return ByteArray(buffer.remaining()).also { buffer.get(it) }.decodeToString()
    }

    @Test fun postSendsTheBodyContentTypeAndHeadersAndReturnsTheResponse() {
        val serving = serve(202, """{"ok":true}""")

        val result = HostBridge.httpRequest(
            "POST".toByteArray(), url.toByteArray(), """{"events":[]}""".toByteArray(), "application/json".toByteArray(),
            "Authorization: Bearer pk_test\nX-Extra: 1".toByteArray(),
        )
        serving.join()

        val lines = request.lines()
        assertEquals("POST /ingest HTTP/1.1", lines.first())
        assertEquals(listOf("Content-Type: application/json"), lines.filter { it.startsWith("Content-Type:") })
        assertEquals(listOf("Authorization: Bearer pk_test"), lines.filter { it.startsWith("Authorization:") })
        assertEquals(listOf("X-Extra: 1"), lines.filter { it.startsWith("X-Extra:") })
        assertEquals("""{"events":[]}""", lines.last())
        assertEquals(202 to """{"ok":true}""", decode(result!!))
    }

    @Test fun anErrorStatusComesBackWithItsBody() {
        val serving = serve(400, "bad body")
        val result = HostBridge.httpRequest("POST".toByteArray(), url.toByteArray(), ByteArray(0), null)
        serving.join()
        assertEquals(400 to "bad body", decode(result!!))
        assertEquals("", retryAfter(result))
    }

    @Test fun retryAfterFollowsTheBody() {
        val serving = serve(503, "busy", "Retry-After: 120\r\n")
        val result = HostBridge.httpRequest("POST".toByteArray(), url.toByteArray(), ByteArray(0), null)
        serving.join()
        assertEquals(503 to "busy", decode(result!!))
        assertEquals("120", retryAfter(result))
    }

    @Test fun aTransportFailureIsNull() {
        val closed = url
        server.close()
        assertNull(HostBridge.httpRequest("POST".toByteArray(), closed.toByteArray(), ByteArray(0), null))
    }

    @Test fun aServerThatNeverAnswersIsNullAtTheReadTimeout() {
        var accepted: Socket? = null
        val holding = thread { accepted = runCatching { server.accept() }.getOrNull() }
        val started = System.nanoTime()

        val result = HostBridge.httpRequest(
            "POST".toByteArray(), url.toByteArray(), """{"model":"emo"}""".toByteArray(), "application/json".toByteArray(),
        )

        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        holding.join()
        accepted?.close()
        assertNull(result)
        assertTrue("${HostBridge.lastHttpRequestError}", HostBridge.lastHttpRequestError is SocketTimeoutException)
        assertTrue("gave up after $elapsedMs ms", elapsedMs in 4_000..11_000)
    }

    @Test fun aHostThatDoesNotResolveIsNull() {
        val started = System.nanoTime()

        val result = HostBridge.httpRequest(
            "POST".toByteArray(), "http://license.invalid/api/v1/license".toByteArray(), ByteArray(0), null,
        )

        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        assertNull(result)
        assertTrue("${HostBridge.lastHttpRequestError}", HostBridge.lastHttpRequestError is UnknownHostException)
        assertTrue("took $elapsedMs ms", elapsedMs < 11_000)
    }
}
