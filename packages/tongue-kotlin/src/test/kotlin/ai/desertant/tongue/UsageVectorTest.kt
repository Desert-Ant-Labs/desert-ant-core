package ai.desertant.tongue

import ai.desertant.tongue.usage.AppInfo
import ai.desertant.tongue.usage.ClientDeps
import ai.desertant.tongue.usage.DAY_MS
import ai.desertant.tongue.usage.IngestBody
import ai.desertant.tongue.usage.IngestEvent
import ai.desertant.tongue.usage.InMemoryStorage
import ai.desertant.tongue.usage.SdkInfo
import ai.desertant.tongue.usage.SendHandle
import ai.desertant.tongue.usage.buildBody
import ai.desertant.tongue.usage.defaultPlatform
import ai.desertant.tongue.usage.makeClient
import ai.desertant.tongue.usage.makeSend
import ai.desertant.tongue.usage.readEnvironment
import com.sun.net.httpserver.HttpServer
import java.net.InetSocketAddress
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import ai.desertant.tongue.usage.UsageClient
import ai.desertant.tongue.usage.UsageState
import ai.desertant.tongue.usage.UsageTurnstile
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

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
                    send = {
                        sends.add(it)
                        null
                    },
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
     * The platform tag has to be one the endpoint accepts. Anything else is a 400,
     * which drops the event: the turnstile looks healthy and the device is simply
     * never billed. This port sent "jvm" until it was checked against the live enum.
     */
    @Test
    fun platformTagIsOneTheEndpointAccepts() {
        val accepted = setOf("ios", "android", "web", "server")
        assertTrue(
            defaultPlatform() in accepted,
            "the endpoint rejects platform ${defaultPlatform()}",
        )
        assertEquals("server", defaultPlatform(), "a JVM is a server")
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
            platform = "server",
            key = "k",
            app = AppInfo("com.acme.app"),
            sdk = SdkInfo(name = "tongue-js", version = "9.9.9"),
            sentAt = "2023-11-14T22:13:20.000Z",
            events = listOf(IngestEvent(deviceId = "d", callCount = 2)),
        )
        assertEquals(
            """{"platform":"server","key":"k","app":{"id":"com.acme.app"},""" +
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
            platform = "server",
            sdk = SdkInfo(version = "9.9.9"),
            sentAt = "2023-11-14T22:13:20.000Z",
            events = listOf(IngestEvent(deviceId = "d", callCount = 7)),
        )
        assertEquals(
            """{"platform":"server","sdk":{"name":"tongue-kotlin","version":"9.9.9"},""" +
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
        var authorization: String? = null
        var body: String? = null

        server.createContext("/api/v1/ingest") { exchange ->
            method = exchange.requestMethod
            contentType = exchange.requestHeaders.getFirst("Content-Type")
            authorization = exchange.requestHeaders.getFirst("Authorization")
            body = exchange.requestBody.readBytes().toString(Charsets.UTF_8)
            exchange.sendResponseHeaders(204, -1)
            exchange.close()
            latch.countDown()
        }
        server.start()
        try {
            val endpoint = "http://127.0.0.1:${server.address.port}/api/v1/ingest"
            // The key goes in the header, so the body built here must not carry one.
            val handle = makeSend(endpoint, "dal_test")(
                IngestBody(
                    platform = "server",
                    app = AppInfo("com.acme.app"),
                    sdk = SdkInfo(name = "tongue-js", version = "9.9.9"),
                    sentAt = "2023-11-14T22:13:20.000Z",
                    events = listOf(IngestEvent(deviceId = "d", callCount = 2)),
                ),
            )
            // The awaitable contract `flushTelemetry()` rests on: it returns once the
            // server has answered, not when the request is queued.
            handle?.await()
            check(latch.await(10, TimeUnit.SECONDS)) { "the transport never reached the server" }
            assertEquals("POST", method)
            assertEquals("application/json", contentType)
            assertEquals("Bearer dal_test", authorization, "the key did not ride the header")
            assertEquals(
                """{"platform":"server","app":{"id":"com.acme.app"},""" +
                    """"sdk":{"name":"tongue-js","version":"9.9.9"},""" +
                    """"sentAt":"2023-11-14T22:13:20.000Z",""" +
                    """"events":[{"name":"load","deviceId":"d","callCount":2}]}""",
                body,
            )
        } finally {
            server.stop(0)
        }
    }

    /**
     * The layer that decides the platform tag and where the key goes had no test:
     * every other case builds a `ClientDeps` literal with `send` already injected,
     * so a wrong platform tag or a dropped key survived the whole suite. This
     * builds the client the way a host does and reads what went on the wire.
     */
    @Test
    fun theClientAHostBuildsPutsTheKeyInExactlyOnePlace() {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val latch = CountDownLatch(1)
        var authorization: String? = null
        var body: String? = null
        server.createContext("/api/v1/ingest") { exchange ->
            authorization = exchange.requestHeaders.getFirst("Authorization")
            body = exchange.requestBody.readBytes().toString(Charsets.UTF_8)
            exchange.sendResponseHeaders(202, -1)
            exchange.close()
            latch.countDown()
        }
        server.start()
        val previousEndpoint = System.getProperty("DAL_INGEST_ENDPOINT")
        val previousKey = System.getProperty("DAL_API_KEY")
        System.setProperty("DAL_INGEST_ENDPOINT", "http://127.0.0.1:${server.address.port}/api/v1/ingest")
        System.setProperty("DAL_API_KEY", "dal_test")
        try {
            val client = makeClient(sdkVersion = "9.9.9", storage = InMemoryStorage())
            client.recordCall()
            client.load()
            check(latch.await(10, TimeUnit.SECONDS)) { "the client never reached the server" }
            assertEquals("Bearer dal_test", authorization, "the key did not ride the header")
            val sent = body!!
            assertTrue(
                sent.contains("\"platform\":\"server\""),
                "a JVM is a server, and the endpoint rejects anything off the enum: $sent",
            )
            assertFalse(sent.contains("\"key\""), "the key rode the body as well as the header: $sent")
        } finally {
            if (previousEndpoint == null) System.clearProperty("DAL_INGEST_ENDPOINT")
            else System.setProperty("DAL_INGEST_ENDPOINT", previousEndpoint)
            if (previousKey == null) System.clearProperty("DAL_API_KEY")
            else System.setProperty("DAL_API_KEY", previousKey)
            server.stop(0)
        }
    }

    /**
     * A key set in code must reach the wire the same way an environment key does,
     * and must win over one: the property set alongside it would otherwise be sent.
     */
    @Test
    fun aKeySetInCodeRidesTheHeaderOverTheEnvironment() {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val latch = CountDownLatch(1)
        var authorization: String? = null
        var body: String? = null
        server.createContext("/api/v1/ingest") { exchange ->
            authorization = exchange.requestHeaders.getFirst("Authorization")
            body = exchange.requestBody.readBytes().toString(Charsets.UTF_8)
            exchange.sendResponseHeaders(202, -1)
            exchange.close()
            latch.countDown()
        }
        server.start()
        val previousEndpoint = System.getProperty("DAL_INGEST_ENDPOINT")
        val previousKey = System.getProperty("DAL_API_KEY")
        val previousCodeKey = DesertAnt.apiKey
        System.setProperty("DAL_INGEST_ENDPOINT", "http://127.0.0.1:${server.address.port}/api/v1/ingest")
        System.setProperty("DAL_API_KEY", "dal_from_property")
        DesertAnt.apiKey = "dal_from_code"
        try {
            val client = makeClient(sdkVersion = "9.9.9", storage = InMemoryStorage())
            client.recordCall()
            client.load()?.await()
            check(latch.await(10, TimeUnit.SECONDS)) { "the client never reached the server" }
            assertEquals("Bearer dal_from_code", authorization, "the key set in code did not win the header")
            assertFalse(body!!.contains("\"key\""), "the key rode the body as well as the header: $body")
        } finally {
            DesertAnt.apiKey = previousCodeKey
            if (previousEndpoint == null) System.clearProperty("DAL_INGEST_ENDPOINT")
            else System.setProperty("DAL_INGEST_ENDPOINT", previousEndpoint)
            if (previousKey == null) System.clearProperty("DAL_API_KEY")
            else System.setProperty("DAL_API_KEY", previousKey)
            server.stop(0)
        }
    }

    /**
     * What `Tongue.flushTelemetry()` documents: a POST the endpoint refuses still
     * returns true, as core and the Node port do. Reporting is best effort.
     */
    @Test
    fun aRefusedPostStillReportsAFinishedFlush() {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val arrived = CountDownLatch(1)
        server.createContext("/api/v1/ingest") { exchange ->
            exchange.requestBody.readBytes()
            // Before the response: once it is sent the client can return and
            // assert before this thread gets here.
            arrived.countDown()
            exchange.sendResponseHeaders(500, -1)
            exchange.close()
        }
        server.start()
        try {
            val endpoint = "http://127.0.0.1:${server.address.port}/api/v1/ingest"
            val client = makeClient(sdkVersion = "9.9.9", storage = InMemoryStorage(), send = makeSend(endpoint))
            val turnstile = UsageTurnstile(client)
            client.start()
            turnstile.record()
            assertTrue(turnstile.flushTelemetry())
            assertEquals(0L, arrived.count, "the flush never reached the server")
        } finally {
            server.stop(0)
        }
    }

    /**
     * `DAL_DEVICE_ID` names the device, as it does in core and the Node port, and
     * wins over the persisted id. The environment first, then the system property.
     */
    @Test
    fun aHostProvidedDeviceIdReplacesThePersistedOne() {
        val previousEnvironment = readEnvironment
        val previousProperty = System.getProperty("DAL_DEVICE_ID")
        try {
            val sent = mutableListOf<IngestBody>()
            fun deviceSent(): String {
                sent.clear()
                val client = makeClient(sdkVersion = "9.9.9", storage = InMemoryStorage(), send = { sent.add(it); null })
                client.recordCall()
                client.load()
                return sent.single().events.single().deviceId
            }

            readEnvironment = { name -> if (name == "DAL_DEVICE_ID") "from-environment" else null }
            System.setProperty("DAL_DEVICE_ID", "from-property")
            assertEquals("from-environment", deviceSent())

            readEnvironment = { null }
            assertEquals("from-property", deviceSent())

            System.clearProperty("DAL_DEVICE_ID")
            assertTrue(deviceSent() !in setOf("from-environment", "from-property"))
        } finally {
            readEnvironment = previousEnvironment
            if (previousProperty == null) System.clearProperty("DAL_DEVICE_ID")
            else System.setProperty("DAL_DEVICE_ID", previousProperty)
        }
    }

    /**
     * `load()` is what `flushTelemetry()` calls before a short-lived JVM exits, so
     * two things have to hold: it posts although the window has not elapsed, and it
     * hands back a send the caller can wait on.
     */
    @Test
    fun forcedLoadPostsInsideTheWindowAndReturnsTheSendInFlight() {
        var state = UsageState()
        val now = 1_700_000_000_000L
        val sends = mutableListOf<IngestBody>()
        var awaited = false
        val client = UsageClient(
            ClientDeps(
                deviceId = "d",
                platform = "server",
                sdkVersion = "0.0.0",
                windowMs = DAY_MS,
                now = { now },
                loadState = { state },
                saveState = { state = it },
                send = {
                    sends.add(it)
                    SendHandle { awaited = true }
                },
            ),
        )

        client.start()
        client.flush()
        client.recordCall(3)

        val handle = client.load()
        assertEquals(2, sends.size, "the forced load did not post inside the window")
        assertEquals(3, sends[1].events.first().callCount)
        assertEquals(now, state.lastActiveAt, "the forced load stamps the window")

        handle?.await()
        assertEquals(true, awaited, "load() did not return the send in flight")
    }

    /**
     * A forced flush takes the pending debounce's place: that timer must be gone,
     * not merely harmless when it fires, and the turnstile must still flush a
     * detection recorded afterwards. Both halves discriminate. Leaving the timer
     * behind sends the next detection a debounce early; leaving the flag set means
     * `record()` never schedules again and that detection is never sent at all.
     *
     * This is where the port drifted from the JavaScript twin, which cancels.
     */
    @Test
    fun aForcedFlushTakesThePendingDebounceAndTheTurnstileStillFlushesLater() {
        var state = UsageState()
        val now = 1_700_000_000_000L
        val sends = mutableListOf<IngestBody>()
        val client = UsageClient(
            ClientDeps(
                deviceId = "d",
                platform = "server",
                sdkVersion = "0.0.0",
                windowMs = DAY_MS,
                now = { now },
                loadState = { state },
                saveState = { state = it },
                send = {
                    sends.add(it)
                    SendHandle { }
                },
            ),
        )
        val turnstile = UsageTurnstile(client, flushAfterMs = 500)
        client.start()

        turnstile.record()
        assertEquals(0, sends.size, "the debounce sent before its delay")

        Thread.sleep(300)
        assertTrue(turnstile.flushTelemetry())
        assertEquals(1, sends.size, "the forced flush did not send")

        // Past the replaced timer's deadline, before the next one's: a timer left
        // behind would have sent by now.
        Thread.sleep(100)
        turnstile.record()
        Thread.sleep(300)
        assertEquals(1, sends.size, "the debounce the flush replaced sent on its own")

        // Past the new debounce: the detection recorded above must arrive.
        Thread.sleep(600)
        assertEquals(2, sends.size, "the turnstile stopped flushing after a forced flush")
    }

    /**
     * A flush right after the debounce fired has nothing left to send, but the
     * POST the debounce started may still be in flight. `flushTelemetry` must
     * wait for it too, or a JVM that exits next drops the event on its daemon
     * sender thread. The server answers slowly so the window is wide open.
     */
    @Test
    fun aForcedFlushAwaitsTheSendTheDebounceStarted() {
        val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val arrived = CountDownLatch(1)
        val answered = CountDownLatch(1)
        server.createContext("/api/v1/ingest") { exchange ->
            exchange.requestBody.readBytes()
            arrived.countDown()
            Thread.sleep(800)
            // Before the response, for the reason the refused-POST test gives.
            // A flush cannot finish until the response is sent, so this still
            // proves it waited.
            answered.countDown()
            exchange.sendResponseHeaders(202, -1)
            exchange.close()
        }
        server.start()
        try {
            val endpoint = "http://127.0.0.1:${server.address.port}/api/v1/ingest"
            val client = makeClient(sdkVersion = "9.9.9", storage = InMemoryStorage(), send = makeSend(endpoint))
            val turnstile = UsageTurnstile(client, flushAfterMs = 50)
            client.start()

            turnstile.record()
            check(arrived.await(10, TimeUnit.SECONDS)) { "the debounce never posted" }
            assertTrue(turnstile.flushTelemetry())
            assertEquals(0L, answered.count, "flushTelemetry returned before the debounced POST finished")
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
