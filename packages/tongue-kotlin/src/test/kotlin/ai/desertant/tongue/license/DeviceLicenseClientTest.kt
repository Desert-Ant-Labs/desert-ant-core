package ai.desertant.tongue.license

import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class DeviceLicenseClientTest {
    private val busy = HttpReply(503, ByteArray(0), null)

    /** The device client with a clock, an executor and a timer the test moves by hand. */
    private class Bench(
        endpoint: String = DEAD_ENDPOINT,
        apiKey: String? = "dal_test_key",
        queueLimit: Int = DEVICE_LICENSE_QUEUE_LIMIT,
        post: (String, ByteArray, String?) -> HttpReply? = ::httpPost,
    ) {
        var clock = System.currentTimeMillis()
        var canStart = true
        val started = ArrayDeque<() -> Unit>()
        val timers = ArrayList<Pair<Long, () -> Unit>>()
        val warnings = CopyOnWriteArrayList<String>()
        val client = DeviceLicenseClient(
            LicenseDeps(
                store = { MemoryStore() },
                identity = { LicenseIdentity("com.acme.app", apiKey, "server") },
                secret = { "0123456789abcdef0123456789abcdef" },
                endpoint = { endpoint },
                post = post,
                now = { clock },
                jitter = { it },
                publicKeys = Vectors.publicKeys,
                warn = { warnings += it },
            ),
            start = { work -> canStart.also { if (it) started.addLast(work) } },
            schedule = { delay, work -> timers += (clock + delay) to work },
            queueLimit = queueLimit,
        )

        fun devices(range: IntRange) = range.forEach { client.modelRan("device-$it") }

        /** Runs every request that has started, and the ones their answers start. */
        fun answer() {
            while (started.isNotEmpty()) started.removeFirst()()
        }

        /** Moves the clock, fires the timers that are due, and answers the requests. */
        fun advance(ms: Long) {
            clock += ms
            while (true) {
                val due = timers.filter { it.first <= clock }.minByOrNull { it.first } ?: break
                timers -= due
                due.second()
            }
            answer()
        }
    }

    @Test
    fun aBurstOf250DevicesIsThreeBatchRequests(): Unit = FakeLicenseServer().use { server ->
        val bench = Bench(server.endpoint)
        bench.devices(1..250)
        assertEquals(1, bench.started.size)
        bench.answer()
        assertEquals(listOf(100, 100), server.requests.map { it.installIds.size })
        bench.advance(DEVICE_LICENSE_WAIT_MS)
        assertEquals(listOf(100, 100, 50), server.requests.map { it.installIds.size })
        assertTrue(server.requests.all { it.path == "/api/v1/licenses" && it.authorization == "Bearer dal_test_key" })
        assertEquals(250, server.requests.flatMap { it.installIds }.toSet().size)
        assertEquals(0, bench.client.pending)
        assertEquals(250, bench.client.holds.count)

        bench.devices(1..250)
        bench.advance(DAY_MS)
        assertEquals(3, server.requests.size)
    }

    @Test
    fun fewerThanABatchGoOutTenSecondsAfterTheFirst(): Unit = FakeLicenseServer().use { server ->
        val bench = Bench(server.endpoint)
        bench.devices(1..2)
        bench.advance(4_000)
        bench.devices(3..5)
        bench.advance(DEVICE_LICENSE_WAIT_MS - 4_001)
        assertEquals(0, server.requests.size)
        bench.advance(1)
        assertEquals(listOf(5), server.requests.map { it.installIds.size })
        assertEquals(0, bench.client.pending)
    }

    @Test
    fun aFlushSendsAPartialBatchAtOnce(): Unit = FakeLicenseServer().use { server ->
        val bench = Bench(server.endpoint)
        bench.devices(1..5)
        bench.client.limitSends(bench.clock + DEVICE_LICENSE_FLUSH_MS)
        bench.client.pump(force = true)
        bench.answer()
        bench.client.endLimit()
        assertEquals(listOf(5), server.requests.map { it.installIds.size })
        assertEquals(0, bench.client.pending)
    }

    @Test
    fun aServerWithoutTheBatchRouteGetsSingleGrantsForAnHour() {
        val server = FakeLicenseServer { if (it.isBatch) Answer(404, "<html>Not Found</html>") else granted() }
        server.use {
            val bench = Bench(server.endpoint)
            bench.devices(1..3)
            bench.advance(DEVICE_LICENSE_WAIT_MS)
            assertEquals(listOf("licenses", "license", "license", "license"), server.requests.map { it.path.substringAfterLast('/') })
            assertEquals(0, bench.client.pending)

            bench.devices(4..4)
            bench.advance(DEVICE_LICENSE_WAIT_MS)
            assertEquals(5, server.requests.size)
            assertFalse(server.requests.last().isBatch)

            bench.advance(DEVICE_LICENSE_SINGLE_GRANTS_MS)
            bench.devices(5..5)
            bench.advance(DEVICE_LICENSE_WAIT_MS)
            assertEquals(listOf("licenses", "license"), server.requests.drop(5).map { it.path.substringAfterLast('/') })
            assertEquals(emptyList(), bench.warnings.toList())
        }
    }

    @Test
    fun aKeyThatCannotBatchIsToldOnce() {
        val server = FakeLicenseServer { if (it.isBatch) Answer(400, """{"error":"batch_not_allowed"}""") else granted() }
        server.use {
            val bench = Bench(server.endpoint)
            bench.devices(1..2)
            bench.advance(DEVICE_LICENSE_WAIT_MS)
            bench.advance(DEVICE_LICENSE_SINGLE_GRANTS_MS)
            bench.devices(3..3)
            bench.advance(DEVICE_LICENSE_WAIT_MS)
            assertEquals(listOf(true, false, false, true, false), server.requests.map { it.isBatch })
            assertTrue("did not accept a batch (HTTP 400)" in bench.warnings.single())
        }
    }

    @Test
    fun withoutAnApiKeyEachDeviceIsOneRequest(): Unit = FakeLicenseServer().use { server ->
        val bench = Bench(server.endpoint, apiKey = null)
        bench.devices(1..3)
        bench.advance(DEVICE_LICENSE_WAIT_MS)
        assertEquals(listOf(false, false, false), server.requests.map { it.isBatch })
    }

    @Test
    fun anItemWithoutALicenseThatVerifiesIsHeldForADay() {
        val forged = Vectors.rows("tokens").first { it["name"] == "bad-signature" }["token"] as String
        val server = FakeLicenseServer { grantedBatch(it, if (it.installIds.size == 3) listOf(Vectors.mint(), null, forged) else emptyList()) }
        server.use {
            val bench = Bench(server.endpoint)
            bench.devices(1..3)
            bench.advance(DEVICE_LICENSE_WAIT_MS)
            assertEquals(0, bench.client.pending)

            bench.advance(DAY_MS - 1)
            bench.devices(1..3)
            assertEquals(0, bench.client.pending)
            bench.advance(1)
            bench.devices(1..3)
            assertEquals(2, bench.client.pending)
            bench.advance(DEVICE_LICENSE_WAIT_MS)
            assertEquals(listOf(3, 2), server.requests.map { it.installIds.size })
            assertEquals(server.requests[0].installIds.drop(1), server.requests[1].installIds)
        }
    }

    @Test
    fun aBatchAnswerWithTheWrongCountIsTriedAgain() {
        val server = FakeLicenseServer { Answer(200, """{"results":[{}]}""") }
        server.use {
            val bench = Bench(server.endpoint)
            bench.devices(1..2)
            bench.advance(DEVICE_LICENSE_WAIT_MS)
            assertEquals(2, bench.client.pending)
            assertTrue("an answer the SDK cannot read" in bench.warnings.single())
            bench.advance(LICENSE_MIN_BACKOFF_MS - 1)
            assertEquals(1, server.requests.size)
            bench.advance(1)
            assertEquals(2, server.requests.size)
        }
    }

    @Test
    fun oneRequestIsOnItsWayAtATime() {
        val batches = Bench()
        batches.devices(1..250)
        assertEquals(1, batches.started.size)

        val singles = Bench(apiKey = null, post = { _, _, _ -> HttpReply(200, granted().body.toByteArray(), null) })
        singles.devices(1..10)
        singles.clock += DEVICE_LICENSE_WAIT_MS
        singles.timers.removeAt(0).second()
        assertEquals(1, singles.started.size)
        singles.started.removeFirst()()
        assertEquals(1, singles.started.size)
        assertEquals(9, singles.client.pending)
    }

    @Test
    fun aFullQueueLeavesNewDevicesOutAndWarnsOnce() {
        val bench = Bench(queueLimit = 3)
        bench.devices(1..6)
        assertEquals(3, bench.client.pending)
        assertTrue("queue is full (3 devices wait)" in bench.warnings.single())
    }

    @Test
    fun everySecondRequestUnansweredHoldsTheFiveMinuteWait() {
        var count = 0
        val bench = Bench(apiKey = null, post = { _, _, _ ->
            if (count++ % 2 == 1) null else HttpReply(200, granted().body.toByteArray(), null)
        })
        bench.devices(1..100)
        bench.advance(DEVICE_LICENSE_WAIT_MS)
        assertEquals(2, count)
        assertEquals(99, bench.client.pending)
        bench.advance(LICENSE_NETWORK_RETRY_MS - 1)
        assertEquals(2, count)
        bench.advance(1)
        assertEquals(4, count)
        assertEquals(98, bench.client.pending)
        bench.advance(LICENSE_NETWORK_RETRY_MS - 1)
        assertEquals(4, count)
    }

    @Test
    fun aForcedFlushStillWaitsForTheTimeTheServerAskedFor() {
        var count = 0
        var answer: HttpReply? = HttpReply(429, ByteArray(0), "3600")
        val bench = Bench(post = { _, _, _ -> count++.let { answer } })
        bench.devices(1..1)
        bench.advance(DEVICE_LICENSE_WAIT_MS)
        assertEquals(1, count)

        bench.client.limitSends(bench.clock + DEVICE_LICENSE_FLUSH_MS)
        bench.client.pump(force = true)
        bench.answer()
        bench.client.endLimit()
        assertEquals(1, count)
        assertEquals(1, bench.client.pending)

        answer = null
        bench.advance(3_600_000)
        assertEquals(2, count)
        bench.client.limitSends(bench.clock + DEVICE_LICENSE_FLUSH_MS)
        bench.client.pump(force = true)
        bench.answer()
        bench.client.endLimit()
        assertEquals(3, count)
    }

    @Test
    fun nothingStartsAfterTheFlushLimitAndAReplacedTimerDoesNothing() {
        var count = 0
        val bench = Bench(post = { _, _, _ -> count++.let { null } })
        bench.devices(1..1)
        bench.advance(DEVICE_LICENSE_WAIT_MS)
        assertEquals(1, count)
        val replaced = bench.timers.single()
        assertEquals(bench.clock + LICENSE_NETWORK_RETRY_MS, replaced.first)

        bench.client.limitSends(bench.clock - 1)
        bench.client.pump(force = true)
        bench.client.endLimit()
        assertEquals(0, bench.started.size)
        assertEquals(listOf(bench.clock + LICENSE_NETWORK_RETRY_MS, bench.clock + DEVICE_LICENSE_WAIT_MS), bench.timers.map { it.first })

        bench.timers -= replaced
        replaced.second()
        assertEquals(1, bench.timers.size)
        assertEquals(0, bench.started.size)

        bench.advance(DEVICE_LICENSE_WAIT_MS)
        assertEquals(1, count)
        bench.advance(LICENSE_NETWORK_RETRY_MS - DEVICE_LICENSE_WAIT_MS)
        assertEquals(2, count)
    }

    @Test
    fun aRequestThatCannotStartStaysInTheQueueAndIsTriedAgain(): Unit = FakeLicenseServer().use { server ->
        val bench = Bench(server.endpoint)
        bench.canStart = false
        bench.devices(1..100)
        assertEquals(0, bench.started.size)
        assertEquals(100, bench.client.pending)
        bench.canStart = true
        bench.advance(DEVICE_LICENSE_WAIT_MS)
        assertEquals(listOf(100), server.requests.map { it.installIds.size })
        assertEquals(0, bench.client.pending)

        val failing = DeviceLicenseClient(
            LicenseDeps(
                store = { MemoryStore() },
                identity = { LicenseIdentity("com.acme.app", null, "server") },
                secret = { null },
                endpoint = { server.endpoint },
                warn = {},
            ),
            start = { throw OutOfMemoryError("unable to create native thread") },
            schedule = { _, _ -> },
        )
        failing.modelRan("device-1")
        failing.limitSends(Long.MAX_VALUE)
        failing.pump(force = true)
        failing.pump(force = true)
        failing.endLimit()
        assertEquals(1, failing.pending)
    }

    @Test
    fun aRuntimeThatCannotStartAThreadDoesNotHoldUpAFlush() {
        val runtime = LicenseRuntime(
            LicenseDeps(
                store = { MemoryStore() },
                identity = { LicenseIdentity("com.acme.app", null, "server") },
                secret = { null },
                endpoint = { DEAD_ENDPOINT },
                warn = {},
            ),
            submit = { _, _ -> throw OutOfMemoryError("unable to create native thread") },
        )
        val started = System.nanoTime()
        runtime.modelLoaded()
        runtime.modelRan("device-1")
        assertFalse(runtime.flush())
        assertFalse(runtime.flush())
        assertTrue((System.nanoTime() - started) / 1_000_000 < 5_000)
        assertEquals(1, runtime.devices.pending)
    }

    @Test
    fun aConnectionFailureDoesNotShortenTheWaitTheServerAskedFor() {
        val wait = DeviceRetryWait()
        assertEquals(3_600_000, wait.failed(HttpReply(429, ByteArray(0), "3600"), 1_000) { 0 })
        assertEquals(3_600_000 - 10, wait.failed(null, 1_010) { 0 })
        assertEquals(3_601_000, wait.retryAt)
        assertEquals(3_601_000, wait.serverWaitUntil)
        assertEquals(1, wait.attempts)
    }

    @Test
    fun aConnectionFailureWaitsFiveMinutesAndIsNoAttempt() {
        val wait = DeviceRetryWait()
        assertEquals(LICENSE_NETWORK_RETRY_MS, wait.failed(null, 1_000) { it })
        assertEquals(1_000 + LICENSE_NETWORK_RETRY_MS, wait.retryAt)
        assertEquals(0, wait.serverWaitUntil)
        assertEquals(0, wait.attempts)
    }

    @Test
    fun eachServerFailureDoublesTheWaitUntilASuccess() {
        val wait = DeviceRetryWait()
        assertEquals(LICENSE_MIN_BACKOFF_MS, wait.failed(busy, 1_000) { it })
        assertEquals(1_000 + LICENSE_MIN_BACKOFF_MS, wait.serverWaitUntil)
        assertEquals(2 * LICENSE_MIN_BACKOFF_MS, wait.failed(busy, wait.retryAt) { it })
        assertEquals(3_600_000, wait.failed(HttpReply(429, ByteArray(0), "3600"), wait.retryAt) { 0 })
        assertEquals(3, wait.attempts)

        wait.succeeded()
        assertEquals(listOf(0L, 0L, 0L), listOf(wait.attempts.toLong(), wait.retryAt, wait.serverWaitUntil))
        assertEquals(LICENSE_MIN_BACKOFF_MS, wait.failed(busy, 9_000_000) { it })
    }
}
