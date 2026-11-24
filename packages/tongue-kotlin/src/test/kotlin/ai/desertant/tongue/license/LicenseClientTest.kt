package ai.desertant.tongue.license

import ai.desertant.tongue.Tongue
import java.io.File
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LicenseClientTest {
    private val secret = "0123456789abcdef0123456789abcdef"

    /** Loads the model, runs it once for each of [deviceIds] (or once without one), and waits for the requests. */
    private fun loadAndDetect(runtime: LicenseRuntime, vararg deviceIds: String): Boolean = withRuntime(runtime) {
        val tongue = Tongue.bundled(null)
        if (deviceIds.isEmpty()) assertEquals("de", tongue.detect("kann ich das haben").language)
        for (deviceId in deviceIds) assertEquals("de", tongue.detect("kann ich das haben", deviceId).language)
        tongue.flushLicenses()
    }

    private fun record(store: LicenseStore, namespace: String = "dal_test_key"): StoredLicense =
        StoredLicense.decode(store.get(licenseStorageKey(namespace)))

    @Test
    fun theFirstLoadAsksOnceAndASecondClientOverTheSameStoreAsksNothing(): Unit = FakeLicenseServer().use { server ->
        val store = MemoryStore()
        assertTrue(loadAndDetect(testRuntime(server.endpoint, store, platform = "android")))

        val request = server.requests.single()
        assertEquals("/api/v1/license", request.path)
        assertEquals("Bearer dal_test_key", request.authorization)
        assertEquals("application/json", request.contentType)
        assertEquals(
            mapOf(
                "installId" to store.get(INSTALL_ID_KEY),
                "model" to "tongue",
                "modelVersion" to "v1.0.0",
                "sdk" to mapOf("name" to "desert-ant-core", "version" to SDK_VERSION),
                "platform" to "android",
                "app" to mapOf("id" to "com.acme.app"),
            ),
            request.body,
        )
        assertEquals(36, UUID.fromString(request.body["installId"] as String).toString().length)

        val kept = record(store)
        assertNotNull(kept.token)
        assertEquals("7e33d8a7-32c1-8f75-9fc5-88a8a6e19e43", kept.licenseId)
        assertEquals(listOf("tongue"), kept.activatedModels)
        assertNull(store.get("ai.desertant.license.dal_test_key"))

        val second = testRuntime(server.endpoint, store, platform = "android")
        assertTrue(loadAndDetect(second))
        assertTrue(loadAndDetect(second))
        assertEquals(1, server.requests.size)
    }

    @Test
    fun theInstallIdAnotherClientStoredIsTheOneSent(): Unit = FakeLicenseServer().use { server ->
        val store = MemoryStore().apply { set(INSTALL_ID_KEY, "7f9c2ba4-e88f-4c6e-9b1a-3d5e8a2f6c01") }
        loadAndDetect(testRuntime(server.endpoint, store, apiKey = null))
        val request = server.requests.single()
        assertEquals("7f9c2ba4-e88f-4c6e-9b1a-3d5e8a2f6c01", request.body["installId"])
        assertNull(request.authorization)
        assertNotNull(record(store, "com.acme.app").token)
    }

    @Test
    fun anExpiredLicenseIsAskedForAgain(): Unit = FakeLicenseServer().use { server ->
        val expired = Vectors.mint(now = System.currentTimeMillis() - 40 * DAY_MS)
        val store = MemoryStore().apply { set(licenseStorageKey("dal_test_key"), StoredLicense(token = expired).encode()) }
        loadAndDetect(testRuntime(server.endpoint, store))
        assertEquals(1, server.requests.size)
        assertTrue(record(store).token != expired)
    }

    @Test
    fun aRefusalIsKeptForADayAndTheModelStillAnswers(): Unit =
        FakeLicenseServer { Answer(422, """{"error":"app_not_allowed","message":"no"}""") }.use { server ->
            val store = MemoryStore()
            val runtime = testRuntime(server.endpoint, store)
            assertTrue(loadAndDetect(runtime))
            assertTrue(loadAndDetect(runtime))
            assertTrue(loadAndDetect(testRuntime(server.endpoint, store)))
            assertEquals(1, server.requests.size)
            val kept = record(store)
            assertNull(kept.token)
            assertTrue(kept.isRefused("tongue", System.currentTimeMillis()))
            assertFalse(kept.isRefused("tongue", System.currentTimeMillis() + DAY_MS + 1))
        }

    @Test
    fun aLicenseThatDoesNotVerifyIsARefusal() {
        val forged = Vectors.rows("tokens").first { it["name"] == "bad-signature" }["token"]
        FakeLicenseServer { Answer(200, """{"token":"$forged"}""") }.use { server ->
            val store = MemoryStore()
            loadAndDetect(testRuntime(server.endpoint, store))
            loadAndDetect(testRuntime(server.endpoint, store))
            assertEquals(1, server.requests.size)
            assertNull(record(store).token)
            assertTrue(record(store).isRefused("tongue", System.currentTimeMillis()))
        }
    }

    @Test
    fun aServerErrorIsNotARefusalAndWaitsBeforeItAsksAgain(): Unit =
        FakeLicenseServer { Answer(503, "<html>Bad Gateway</html>", retryAfter = "3600") }.use { server ->
            val store = MemoryStore()
            val runtime = testRuntime(server.endpoint, store)
            assertTrue(loadAndDetect(runtime))
            assertTrue(loadAndDetect(runtime))
            assertEquals(1, server.requests.size)
            assertNull(record(store).refusedAt)
        }

    @Test
    fun theModelAnswersWhileTheServerDoesNot() {
        val arrived = CountDownLatch(1)
        val release = CountDownLatch(1)
        val server = FakeLicenseServer {
            arrived.countDown()
            release.await(30, TimeUnit.SECONDS)
            grantedEither(it)
        }
        server.use {
            withRuntime(testRuntime(server.endpoint)) {
                val tongue = Tongue.bundled(null)
                assertTrue(arrived.await(10, TimeUnit.SECONDS))
                assertEquals("de", tongue.detect("kann ich das haben").language)
                assertEquals("de", tongue.detect("kann ich das haben", "device-1").language)
                assertEquals(1, release.count)
                val threads = Thread.getAllStackTraces().keys.filter { it.name.startsWith("tongue-") }
                assertTrue(threads.isNotEmpty() && threads.all { it.isDaemon })
                release.countDown()
                assertTrue(tongue.flushLicenses())
            }
        }
    }

    @Test
    fun anUnreachableServerNeverStopsTheModel() {
        val store = MemoryStore()
        assertTrue(loadAndDetect(testRuntime(DEAD_ENDPOINT, store)))
        assertNotNull(store.get(INSTALL_ID_KEY))
        assertNull(store.get(licenseStorageKey("dal_test_key")))
        assertTrue(loadAndDetect(testRuntime("not a url", store)))
    }

    @Test
    fun aServerWithASecretAsksOncePerDeviceAndNotForItself(): Unit = FakeLicenseServer().use { server ->
        val runtime = testRuntime(server.endpoint, secret = secret)
        assertTrue(loadAndDetect(runtime, "device-1", "device-2", "device-3", "device-1"))
        assertTrue(loadAndDetect(runtime, "device-3", "device-2", "device-1"))

        val request = server.requests.single()
        assertEquals("/api/v1/licenses", request.path)
        assertEquals("Bearer dal_test_key", request.authorization)
        assertEquals(
            mapOf(
                "sdk" to mapOf("name" to "desert-ant-core", "version" to SDK_VERSION),
                "platform" to "server",
                "app" to mapOf("id" to "com.acme.app"),
                "items" to listOf("device-1", "device-2", "device-3").map {
                    mapOf("installId" to deviceInstallId(it, "server:com.acme.app", secret), "model" to "tongue", "modelVersion" to "v1.0.0")
                },
            ),
            request.body,
        )
        assertEquals(3, runtime.devices.holds.count)
        assertEquals(0, runtime.devices.pending)
    }

    @Test
    fun aServerCallWithoutADeviceIdAsksNothingAndWarnsOnce(): Unit = FakeLicenseServer().use { server ->
        val warnings = CopyOnWriteArrayList<String>()
        val runtime = testRuntime(server.endpoint, secret = secret, warnings = warnings)
        assertTrue(loadAndDetect(runtime))
        assertTrue(loadAndDetect(runtime))
        assertEquals(0, server.requests.size)
        assertEquals(1, warnings.size)
        assertTrue("no deviceId" in warnings.single())
    }

    @Test
    fun aServerWithoutASecretLicensesItselfAndHashesTheDeviceIdWithTheKey(): Unit = FakeLicenseServer().use { server ->
        val warnings = CopyOnWriteArrayList<String>()
        val store = MemoryStore()
        assertTrue(loadAndDetect(testRuntime(server.endpoint, store, warnings = warnings), "device-1", "device-1"))
        assertEquals(
            setOf(store.get(INSTALL_ID_KEY), deviceInstallId("device-1", "server:com.acme.app", null, "dal_test_key")),
            server.requests.flatMap { it.installIds }.toSet(),
        )
        assertEquals(setOf("/api/v1/license", "/api/v1/licenses"), server.requests.map { it.path }.toSet())
        assertEquals(2, server.requests.size)
        assertTrue("without a secret" in warnings.single())
    }

    @Test
    fun aPhoneIsOneDeviceWhateverDeviceIdACallNames(): Unit = FakeLicenseServer().use { server ->
        val store = MemoryStore()
        assertTrue(loadAndDetect(testRuntime(server.endpoint, store, platform = "android", secret = secret), "device-1", "device-2"))
        assertEquals(listOf<Any?>(store.get(INSTALL_ID_KEY)), server.requests.map { it.body["installId"] })
    }

    @Test
    fun aRefusedDeviceIsNotAskedForAgain(): Unit =
        FakeLicenseServer { Answer(400, """{"error":"invalid_request"}""") }.use { server ->
            val runtime = testRuntime(server.endpoint, secret = secret)
            assertTrue(loadAndDetect(runtime, "device-1"))
            assertTrue(loadAndDetect(runtime, "device-1"))
            assertEquals(listOf("/api/v1/licenses", "/api/v1/license"), server.requests.map { it.path })
        }

    @Test
    fun flushIsFalseWhileADeviceLicenseIsLeftAndTriesItAgain() {
        val warnings = CopyOnWriteArrayList<String>()
        val runtime = testRuntime(DEAD_ENDPOINT, secret = secret, warnings = warnings)
        assertFalse(loadAndDetect(runtime, "device-1"))
        assertEquals(1, runtime.devices.pending)
        assertTrue("tries again" in warnings.single())

        FakeLicenseServer().use { server ->
            var endpoint = DEAD_ENDPOINT
            val store = MemoryStore()
            val outage = LicenseRuntime(
                LicenseDeps(
                    store = { store },
                    identity = { LicenseIdentity("com.acme.app", null, "server") },
                    secret = { secret },
                    endpoint = { endpoint },
                    publicKeys = Vectors.publicKeys,
                    warn = {},
                ),
            )
            assertFalse(loadAndDetect(outage, "device-1"))
            endpoint = server.endpoint
            assertTrue(loadAndDetect(outage, "device-1"))
            assertEquals(1, server.requests.size)
            assertEquals(0, outage.devices.pending)
        }
    }

    @Test
    fun theFileStoreKeepsALicenseForTheNextProcess() {
        val directory = File(Files.createTempDirectory("tongue-license").toFile(), "made/on/first/write")
        val apiKey = "dal_" + "k".repeat(120)
        val warnings = CopyOnWriteArrayList<String>()
        FakeLicenseServer().use { server ->
            assertTrue(loadAndDetect(testRuntime(server.endpoint, FileStore(directory, warnings::add), apiKey = apiKey)))
            assertTrue(loadAndDetect(testRuntime(server.endpoint, FileStore(directory, warnings::add), apiKey = apiKey)))
            assertEquals(1, server.requests.size)
            assertEquals("Bearer $apiKey", server.requests.single().authorization)
            assertNotNull(record(FileStore(directory, warnings::add), apiKey).token)
            assertEquals(server.requests.single().body["installId"], FileStore(directory, warnings::add).get(INSTALL_ID_KEY))
        }
        assertEquals(setOf("tongue.lock", "tongue.properties"), directory.list()!!.toSet())
        assertEquals(emptyList(), warnings.toList())
    }

    @Test
    fun aFileStoreThatCannotWriteKeepsItsValuesInMemoryAndWarnsOnce() {
        val notADirectory = Files.createTempFile("tongue-license", ".txt").toFile()
        for (directory in listOf(notADirectory, null)) {
            val warnings = CopyOnWriteArrayList<String>()
            val store = FileStore(directory, warnings::add)
            assertNull(store.get("a"))
            store.set("a", "1")
            store.set("b", "2")
            assertEquals("1", store.get("a"))
            assertEquals("2", store.get("b"))
            assertEquals(1, warnings.size)
            FakeLicenseServer().use { server ->
                val runtime = testRuntime(server.endpoint, store)
                assertTrue(loadAndDetect(runtime))
                assertTrue(loadAndDetect(runtime))
                assertEquals(1, server.requests.size)
            }
            assertEquals(1, warnings.size)
        }
    }

    @Test
    fun theStateDirectoryIsTheSetOneThenTheConfigDirectory() {
        val none: (String) -> String? = { null }
        assertEquals(File("/srv/state"), stateDirectory({ mapOf("DAL_STATE_DIR" to "/srv/state", "XDG_CONFIG_HOME" to "/xdg")[it] }, "/home/a"))
        assertEquals(File("/xdg/desert-ant"), stateDirectory({ mapOf("DAL_STATE_DIR" to "", "XDG_CONFIG_HOME" to "/xdg")[it] }, "/home/a"))
        assertEquals(File("/home/a/.config/desert-ant"), stateDirectory(none, "/home/a"))
        assertNull(stateDirectory(none, "?"))
        assertNull(stateDirectory(none, null))
    }

    @Test
    fun onAndroidALoadWithoutAStoreAsksNothingUntilALoadBringsOne() = FakeLicenseServer().use { server ->
        val warnings = CopyOnWriteArrayList<String>()
        var attached = false
        val store = MemoryStore()
        val runtime = testRuntime(server.endpoint, store, platform = "android", warnings = warnings, keepsLicenses = { attached })
        assertTrue(loadAndDetect(runtime))
        assertTrue(loadAndDetect(runtime))
        assertEquals(0, server.requests.size)
        assertNull(store.get(INSTALL_ID_KEY))
        assertTrue("Pass the Context" in warnings.single())

        attached = true
        assertTrue(loadAndDetect(runtime))
        assertEquals(1, server.requests.size)
        assertEquals(1, warnings.size)

        val server2 = testRuntime(server.endpoint, platform = "server", keepsLicenses = { false })
        assertTrue(loadAndDetect(server2))
        assertEquals(2, server.requests.size)
    }

    @Test
    fun theInstallIdSentIsTheOneTheStoreHoldsAfterTheWrite() = FakeLicenseServer().use { server ->
        val store = object : LicenseStore {
            private val values = HashMap<String, String>()
            override fun get(key: String): String? = values[key]
            override fun set(key: String, value: String) {
                values[key] = if (key == INSTALL_ID_KEY) "written-by-the-core-first" else value
            }
        }
        assertTrue(loadAndDetect(testRuntime(server.endpoint, store)))
        assertEquals("written-by-the-core-first", server.requests.single().body["installId"])
    }

    @Test
    fun anAnswerOverAMegabyteIsAFailedAnswer() {
        val long = """{"token":"${Vectors.mint()}","padding":"${"x".repeat(1_100_000)}"}"""
        FakeLicenseServer { Answer(200, long) }.use { server ->
            val store = MemoryStore()
            assertTrue(loadAndDetect(testRuntime(server.endpoint, store)))
            assertEquals(1, server.requests.size)
            assertNull(store.get(licenseStorageKey("dal_test_key")))
        }
        assertEquals(11, readAtMost(ByteArray(50).inputStream(), 10).size)
        assertEquals(10, readAtMost(ByteArray(10).inputStream(), 10).size)
    }

    @Test
    fun anErrorInTheLicenseCodeNeverReachesTheCaller() {
        val broken: (String, ByteArray, String?) -> HttpReply? = { _, _, _ -> throw NoClassDefFoundError("javax/crypto/Mac") }
        assertTrue(loadAndDetect(testRuntime(DEAD_ENDPOINT, post = broken)))
        assertFalse(loadAndDetect(testRuntime(DEAD_ENDPOINT, secret = secret, post = broken), "device-1"))
        val failing = LicenseRuntime(
            LicenseDeps(
                store = { throw StackOverflowError() },
                identity = { throw OutOfMemoryError("test") },
                secret = { secret },
                endpoint = { DEAD_ENDPOINT },
            ),
        )
        assertTrue(loadAndDetect(failing))
    }

    @Test
    fun aHoldLastsUntilItsTimeAndTheHoldsStayWithinTheirCapacity() {
        val holds = DeviceLicenseHolds(capacity = 4)
        assertTrue(holds.begin("a", 0))
        assertFalse(holds.begin("a", DEVICE_LICENSE_REQUEST_HOLD_MS - 1))
        assertTrue(holds.begin("a", DEVICE_LICENSE_REQUEST_HOLD_MS))
        holds.hold("a", 30 * DAY_MS)
        assertFalse(holds.begin("a", 29 * DAY_MS))
        assertTrue(holds.begin("a", 30 * DAY_MS))

        // Holds that ended make room first, so the ones that still run are kept.
        for (device in listOf("b", "c", "d")) holds.hold(device, 40 * DAY_MS)
        assertTrue(holds.begin("e", 35 * DAY_MS))
        assertEquals(4, holds.count)
        for (device in listOf("b", "c", "d")) assertFalse(holds.begin(device, 35 * DAY_MS))

        // With every hold still running, a new device is taken and the oldest half is forgotten.
        assertTrue(holds.begin("f", 35 * DAY_MS))
        assertTrue(holds.count <= 4)
        assertFalse(holds.begin("f", 35 * DAY_MS))
    }
}
