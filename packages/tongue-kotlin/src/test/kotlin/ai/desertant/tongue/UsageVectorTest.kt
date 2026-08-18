package ai.desertant.tongue

import ai.desertant.tongue.usage.AppInfo
import ai.desertant.tongue.usage.ClientDeps
import ai.desertant.tongue.usage.IngestBody
import ai.desertant.tongue.usage.IngestEvent
import ai.desertant.tongue.usage.SdkInfo
import ai.desertant.tongue.usage.buildBody
import ai.desertant.tongue.usage.makeSend
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import ai.desertant.tongue.usage.UsageClient
import ai.desertant.tongue.usage.UsageState
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Replays `usage_vectors.json` through this port's hand-written [UsageClient].
 *
 * The JavaScript port replays the identical file; the Swift SDK uses
 * desert-ant-core's client directly rather than porting it. Three copies of one
 * state machine is exactly where drift hides, and a wrong turnstile is a billing
 * error rather than a visible bug, so the contract is pinned here the same way the
 * model's normalizer, hasher and router are. See docs/USAGE.md.
 */
class UsageVectorTest {

    @Test
    fun turnstileMatchesTheSharedContract() {
        val json = read("usage_vectors.json")
        val windowMs = numberField(json, "windowMs") ?: error("no windowMs")

        val cases = caseObjects(json)
        check(cases.isNotEmpty()) { "no cases in usage_vectors.json" }

        for (case in cases) {
            val name = stringField(case, "name") ?: "unnamed"
            var state = UsageState(
                numberField(case, "stateLastActiveAt") ?: 0,
                (numberField(case, "stateCarry") ?: 0).toInt(),
            )
            var now = 0L
            val sends = mutableListOf<IngestBody>()

            val client = UsageClient(
                ClientDeps(
                    deviceId = "device-under-test",
                    platform = "test",
                    sdkVersion = "0.0.0",
                    windowMs = windowMs,
                    now = { now },
                    loadState = { state },
                    saveState = { state = it },
                    send = { sends.add(it) },
                ),
            )

            val kinds = stringArray(case, "stepKinds")
            val ats = numberArray(case, "stepAt")
            val ns = numberArray(case, "stepN")
            kinds.forEachIndexed { i, kind ->
                now = ats[i]
                when (kind) {
                    "start" -> client.start()
                    "flush" -> client.flush()
                    "record" -> client.recordCall(ns[i].toInt())
                    else -> error("unknown step $kind")
                }
            }

            val expected = numberArray(case, "sendCounts")
            assertEquals(expected.size, sends.size, "$name: send count")
            expected.forEachIndexed { i, count ->
                val event = sends[i].events.first()
                assertEquals("load", event.name, "$name: event name")
                assertEquals("device-under-test", event.deviceId, "$name: deviceId")
                assertEquals(count.toInt(), event.callCount ?: -1, "$name: callCount[$i]")
            }
            assertEquals(
                numberField(case, "finalLastActiveAt"), state.lastActiveAt, "$name: final lastActiveAt",
            )
            assertEquals(
                (numberField(case, "finalCarry") ?: 0).toInt(), state.carryCallCount, "$name: final carry",
            )
        }
    }

    /**
     * The bytes on the wire, pinned against the JavaScript port's identical
     * assertion in test/usage.test.js. Field order is part of the contract, and
     * nothing checked it before — Wire.kt claimed the two ports were
     * byte-identical while the JS port actually emitted key and app last.
     */
    @Test
    fun wireBodyMatchesCoreFieldOrder() {
        val body = IngestBody(
            platform = "node",
            key = "k",
            app = AppInfo("com.acme.app"),
            sdk = SdkInfo(name = "tongue-js", version = "9.9.9"),
            sentAt = "2023-11-14T22:13:20.000Z",
            events = listOf(IngestEvent(deviceId = "d", callCount = 2)),
        )
        assertEquals(
            """{"platform":"node","key":"k","app":{"id":"com.acme.app"},""" +
                """"sdk":{"name":"tongue-js","version":"9.9.9"},""" +
                """"sentAt":"2023-11-14T22:13:20.000Z",""" +
                """"events":[{"name":"load","deviceId":"d","callCount":2}]}""",
            buildBody(body),
        )
    }

    /**
     * The keyless body, asserted exactly. Equality is the check that matters:
     * substring searches for leaked text give false positives ("de" is inside
     * "deviceId"), whereas pinning the whole string proves nothing beyond these
     * fields can appear — no detected text, no language, no reliability.
     */
    @Test
    fun keylessWireBodyIsExactlyTheseFields() {
        val body = IngestBody(
            platform = "jvm",
            sdk = SdkInfo(version = "9.9.9"),
            sentAt = "2023-11-14T22:13:20.000Z",
            events = listOf(IngestEvent(deviceId = "d", callCount = 7)),
        )
        assertEquals(
            """{"platform":"jvm","sdk":{"name":"tongue-kotlin","version":"9.9.9"},""" +
                """"sentAt":"2023-11-14T22:13:20.000Z",""" +
                """"events":[{"name":"load","deviceId":"d","callCount":7}]}""",
            buildBody(body),
        )
    }

    /**
     * Drives the real transport at a local server.
     *
     * Every other turnstile test injects `send`, so the HTTP path itself had never
     * executed: nothing proved a body ever left the process. The destination stays
     * hardcoded for real use — only this test passes an endpoint.
     */
    @Test
    fun transportActuallyPostsTheBodyOverHttp() {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val latch = CountDownLatch(1)
        var method: String? = null
        var contentType: String? = null
        var body: String? = null

        server.createContext("/api/v1/ingest") { exchange ->
            method = exchange.requestMethod
            contentType = exchange.requestHeaders.getFirst("Content-Type")
            body = exchange.requestBody.readBytes().toString(Charsets.UTF_8)
            exchange.sendResponseHeaders(204, -1)
            exchange.close()
            latch.countDown()
        }
        server.start()
        try {
            val endpoint = "http://127.0.0.1:${server.address.port}/api/v1/ingest"
            makeSend(endpoint)(
                IngestBody(
                    platform = "jvm",
                    key = "k",
                    app = AppInfo("com.acme.app"),
                    sdk = SdkInfo(name = "tongue-js", version = "9.9.9"),
                    sentAt = "2023-11-14T22:13:20.000Z",
                    events = listOf(IngestEvent(deviceId = "d", callCount = 2)),
                ),
            )
            check(latch.await(10, TimeUnit.SECONDS)) { "the transport never reached the server" }
            assertEquals("POST", method)
            assertEquals("application/json", contentType)
            assertEquals(
                """{"platform":"jvm","key":"k","app":{"id":"com.acme.app"},""" +
                    """"sdk":{"name":"tongue-js","version":"9.9.9"},""" +
                    """"sentAt":"2023-11-14T22:13:20.000Z",""" +
                    """"events":[{"name":"load","deviceId":"d","callCount":2}]}""",
                body,
            )
        } finally {
            server.stop(0)
        }
    }

    // A reader for this document's shape only: flat objects inside "cases", whose
    // values are numbers, strings, or arrays of those. Same reason the model
    // vectors have one — the artifact takes no JSON dependency, so neither do its
    // tests. The vectors are deliberately free of nested objects so this stays
    // this short.
    private fun read(name: String): String =
        javaClass.classLoader.getResourceAsStream(name)?.use { it.readBytes().toString(Charsets.UTF_8) }
            ?: error("$name is missing from the test resources")

    private fun caseObjects(json: String): List<String> {
        val start = json.indexOf("\"cases\"")
        if (start < 0) return emptyList()
        val open = json.indexOf('[', start)
        val out = mutableListOf<String>()
        var depth = 0
        var objectStart = -1
        var index = open
        var inString = false
        var escaped = false
        while (index < json.length) {
            val c = json[index]
            when {
                escaped -> escaped = false
                c == '\\' && inString -> escaped = true
                c == '"' -> inString = !inString
                inString -> {}
                c == '{' -> { if (depth == 0) objectStart = index; depth++ }
                c == '}' -> { depth--; if (depth == 0 && objectStart >= 0) { out.add(json.substring(objectStart, index + 1)); objectStart = -1 } }
                c == ']' && depth == 0 -> return out
            }
            index++
        }
        return out
    }

    private fun stringField(obj: String, key: String): String? =
        Regex("\"$key\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"").find(obj)?.groupValues?.get(1)

    private fun numberField(obj: String, key: String): Long? =
        Regex("\"$key\"\\s*:\\s*(-?\\d+)").find(obj)?.groupValues?.get(1)?.toLongOrNull()

    private fun arrayBody(obj: String, key: String): String? =
        Regex("\"$key\"\\s*:\\s*\\[([^\\]]*)\\]").find(obj)?.groupValues?.get(1)

    private fun numberArray(obj: String, key: String): List<Long> =
        arrayBody(obj, key)?.split(",")?.mapNotNull { it.trim().toLongOrNull() } ?: emptyList()

    private fun stringArray(obj: String, key: String): List<String> =
        arrayBody(obj, key)
            ?.split(",")
            ?.map { it.trim().removeSurrounding("\"") }
            ?.filter { it.isNotEmpty() }
            ?: emptyList()
}
