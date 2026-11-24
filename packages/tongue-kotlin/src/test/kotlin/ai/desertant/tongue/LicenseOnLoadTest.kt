package ai.desertant.tongue

import ai.desertant.tongue.license.DEAD_ENDPOINT
import ai.desertant.tongue.license.FakeLicenseServer
import ai.desertant.tongue.license.LicenseDeps
import ai.desertant.tongue.license.LicenseHost
import ai.desertant.tongue.license.LicenseIdentity
import ai.desertant.tongue.license.LicenseRuntime
import ai.desertant.tongue.license.MODEL_VERSION
import ai.desertant.tongue.license.MemoryStore
import ai.desertant.tongue.license.SDK_VERSION
import ai.desertant.tongue.license.Vectors
import ai.desertant.tongue.license.deviceInstallId
import ai.desertant.tongue.license.testRuntime
import ai.desertant.tongue.license.trimmedKey
import ai.desertant.tongue.license.withRuntime
import java.io.File
import java.io.IOException
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LicenseOnLoadTest {
    @AfterTest
    fun reset() {
        for (name in listOf("configuredApiKey", "configuredDeviceIdSecret")) {
            DesertAnt::class.java.getDeclaredField(name).apply { isAccessible = true }.set(null, null)
        }
    }

    /** A runtime over [endpoint] that reads the key and the secret an app sets with [DesertAnt.configure]. */
    private fun configuredRuntime(endpoint: String) = LicenseRuntime(
        LicenseDeps(
            store = MemoryStore().let { store -> { store } },
            identity = { LicenseIdentity("com.acme.app", trimmedKey(DesertAnt.currentApiKey), "server") },
            secret = { DesertAnt.currentDeviceIdSecret },
            endpoint = { endpoint },
            publicKeys = Vectors.publicKeys,
            warn = {},
        ),
    )

    @Test
    fun aLoadAsksForALicenseAndNothingElseIsSent() {
        val sent = CopyOnWriteArrayList<URI>()
        val realSelector = ProxySelector.getDefault()
        ProxySelector.setDefault(object : ProxySelector() {
            override fun select(uri: URI): List<Proxy> {
                sent += uri
                return listOf(Proxy.NO_PROXY)
            }

            override fun connectFailed(uri: URI, address: SocketAddress, error: IOException) {}
        })
        try {
            FakeLicenseServer().use { server ->
                DesertAnt.configure("  dal_from_configure\n")
                withRuntime(configuredRuntime(server.endpoint)) {
                    val tongue = Tongue.bundled(null)
                    repeat(3) { assertEquals("de", tongue.detect("kann ich das haben").language) }
                    assertEquals("de", tongue.detect("kann ich das haben", topK = 1).language)
                    assertTrue(tongue.flushLicenses())
                    assertTrue(Tongue.bundled(null).flushLicenses())
                }
                assertEquals(listOf(URI(server.endpoint + "license")), sent.toList())
                assertEquals("Bearer dal_from_configure", server.requests.single().authorization)
                assertEquals("tongue", server.requests.single().body["model"])
            }
        } finally {
            ProxySelector.setDefault(realSelector)
        }
    }

    @Test
    fun aServerConfiguredWithASecretAsksForEachDeviceACallNames(): Unit = FakeLicenseServer().use { server ->
        val secret = "0123456789abcdef0123456789abcdef"
        DesertAnt.configure("dal_server_key", " $secret\n")
        withRuntime(configuredRuntime(server.endpoint)) {
            val tongue = Tongue.bundled(null)
            assertEquals("de", tongue.detect("kann ich das haben", "device-1").language)
            assertEquals("de", tongue.detect("kann ich das haben", "device-1", 2).language)
            assertEquals("de", tongue.detect("kann ich das haben", deviceId = "device-2", topK = 1).language)
            assertTrue(tongue.flushLicenses())
        }
        assertEquals(
            setOf<Any?>(
                deviceInstallId("device-1", "server:com.acme.app", secret),
                deviceInstallId("device-2", "server:com.acme.app", secret),
            ),
            server.requests.single().installIds.toSet(),
        )
        assertEquals("/api/v1/licenses", server.requests.single().path)
    }

    @Test
    fun aDetectionNeverFailsOrWaitsWhenTheServerIsUnreachable(): Unit = withRuntime(testRuntime(DEAD_ENDPOINT)) {
        val started = System.nanoTime()
        val tongue = Tongue.bundled(null)
        val detection = tongue.detect("kann ich das haben")
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        assertEquals("de", detection.language)
        assertTrue(elapsedMs < 5_000, "load and detect took $elapsedMs ms")
        assertTrue(tongue.flushLicenses())
    }

    @Test
    fun aGradleTestRunNeverPointsAtTheLicenseServer() {
        assertEquals(DEAD_ENDPOINT, LicenseHost.endpoint())
    }

    @Test
    fun theCoreStillHasTheAccessorTongueReadsItsKeyThrough() {
        val native = File("../../kotlin/src/main/kotlin/ai/desertant/DesertAntNative.kt").readText()
        assertTrue("object DesertAntNative" in native)
        assertTrue("    @JvmStatic\n    fun apiKey(): ByteArray =" in native)
        val rules = File("../../kotlin/consumer-rules.pro").readText()
        assertTrue("-keep class ai.desertant.DesertAntNative { public static *; }" in rules)
        assertNull(Tongue::class.java.classLoader.getResource("META-INF/proguard/tongue.pro"))
    }

    @Test
    fun theVersionsSentAreTheOnesTheRepoStates() {
        assertEquals(File("../../VERSION").readText().trim(), SDK_VERSION)
        val revision = Regex("revision = \"([^\"]+)\"").find(File("../../Sources/Tongue/Catalog.swift").readText())
        assertEquals(revision!!.groupValues[1], MODEL_VERSION)
    }

    @Test
    fun aNullDeviceIdIsACallWithoutOne() = FakeLicenseServer().use { server ->
        withRuntime(configuredRuntime(server.endpoint)) {
            val tongue = Tongue.bundled(null)
            val missing: String? = null
            assertEquals("de", tongue.detect("kann ich das haben", missing).language)
            assertEquals("de", tongue.detect("kann ich das haben", null, 2).language)
            assertEquals(2, tongue.detect("kann ich das haben", deviceId = null, topK = 2).candidates.size)
            assertEquals(1, tongue.detect("kann ich das haben", 1).candidates.size)
            assertTrue(tongue.flushLicenses())
        }
        assertEquals(1, server.requests.size)
        assertEquals(
            setOf("[String]", "[String, int]", "[String, String]", "[String, String, int]"),
            Tongue::class.java.methods.filter { it.name == "detect" }.map { m -> m.parameterTypes.map { it.simpleName }.toString() }.toSet(),
        )
    }
}
