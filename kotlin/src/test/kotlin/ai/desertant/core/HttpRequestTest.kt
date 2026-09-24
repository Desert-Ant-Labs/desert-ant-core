package ai.desertant.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.nio.ByteBuffer
import kotlin.concurrent.thread

class HttpRequestTest {
    // A one-shot HTTP/1.1 server on a plain socket: the Android unit-test
    // classpath has no com.sun.net.httpserver.
    private val server = ServerSocket(0, 1, InetAddress.getLoopbackAddress())
    private val url get() = "http://127.0.0.1:${server.localPort}/ingest"
    private var request = ""

    @After fun stop() = server.close()

    private fun serve(status: Int, reply: String) = thread {
        server.accept().use { socket ->
            val input = socket.getInputStream().bufferedReader()
            val head = generateSequence { input.readLine() }.takeWhile { it.isNotEmpty() }.toList()
            val length = head.firstOrNull { it.startsWith("Content-Length:", ignoreCase = true) }
                ?.substringAfter(':')?.trim()?.toInt() ?: 0
            val body = CharArray(length).also { var read = 0; while (read < length) read += input.read(it, read, length - read) }
            request = (head + String(body)).joinToString("\n")
            val bytes = reply.toByteArray()
            socket.getOutputStream().write(
                "HTTP/1.1 $status X\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray() + bytes,
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

    @Test fun postSendsTheBodyAndContentTypeAndReturnsTheResponse() {
        val serving = serve(202, """{"ok":true}""")

        val result = HostBridge.httpRequest(
            "POST".toByteArray(), url.toByteArray(), """{"events":[]}""".toByteArray(), "application/json".toByteArray(),
        )
        serving.join()

        val lines = request.lines()
        assertEquals("POST /ingest HTTP/1.1", lines.first())
        assertEquals(listOf("Content-Type: application/json"), lines.filter { it.startsWith("Content-Type:") })
        assertEquals("""{"events":[]}""", lines.last())
        assertEquals(202 to """{"ok":true}""", decode(result!!))
    }

    @Test fun anErrorStatusComesBackWithItsBody() {
        val serving = serve(400, "bad body")
        val result = HostBridge.httpRequest("POST".toByteArray(), url.toByteArray(), ByteArray(0), null)
        serving.join()
        assertEquals(400 to "bad body", decode(result!!))
    }

    @Test fun aTransportFailureIsNull() {
        val closed = url
        server.close()
        assertNull(HostBridge.httpRequest("POST".toByteArray(), closed.toByteArray(), ByteArray(0), null))
    }
}
