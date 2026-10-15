package ai.desertant.tongue

import java.io.IOException
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ProxySelector
import java.net.SocketAddress
import java.net.URI
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@Suppress("DEPRECATION")
class DeprecatedSettingsTest {
    @AfterTest
    fun reset() {
        DesertAnt.apiKey = null
        DesertAnt.sendsDeviceContext = true
    }

    @Test
    fun nothingIsSentAndSettingsFromEarlierReleasesChangeNothing() {
        val requests = mutableListOf<URI>()
        val realSelector = ProxySelector.getDefault()
        ProxySelector.setDefault(object : ProxySelector() {
            override fun select(uri: URI): List<Proxy> {
                synchronized(requests) { requests += uri }
                return listOf(Proxy(Proxy.Type.HTTP, InetSocketAddress("127.0.0.1", 9)))
            }

            override fun connectFailed(uri: URI, address: SocketAddress, error: IOException) {}
        })
        try {
            val tongue = Tongue.bundled()
            assertEquals("de", tongue.detect("kann ich das haben").language)
            assertTrue(tongue.flushTelemetry())

            DesertAnt.apiKey = "pk_test_unused"
            DesertAnt.sendsDeviceContext = false
            assertEquals("de", tongue.detect("kann ich das haben").language)
            assertTrue(tongue.flushTelemetry())

            assertEquals(emptyList(), synchronized(requests) { requests.toList() })
        } finally {
            ProxySelector.setDefault(realSelector)
        }
    }
}
