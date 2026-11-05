package ai.desertant.core

import ai.desertant.DesertAntNative
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class DesertAntTest {
    @After fun reset() {
        DesertAnt.apiKey = null
        DesertAnt.logLevel = LogLevel.WARNING
        DesertAnt.logger = null
    }

    /** The default level crosses as the core's raw value for warning. */
    @Test fun defaultLogLevelIsWarning() {
        assertEquals(2, DesertAntNative.logLevel())
    }

    @Test fun logLevelSetInCodeCrossesTheBridge() {
        DesertAnt.logLevel = LogLevel.DEBUG
        assertEquals(0, DesertAntNative.logLevel())
        DesertAnt.logLevel = LogLevel.OFF
        assertEquals(4, DesertAntNative.logLevel())
    }

    /** A message from the core reaches the app's logger with its level and source decoded. */
    @Test fun loggerReceivesCoreMessages() {
        val received = mutableListOf<Triple<LogLevel, String, String>>()
        DesertAnt.logger = { level, source, message -> received.add(Triple(level, source, message)) }
        DesertAntNative.log(2, "litert".toByteArray(), "GPU accelerator could not be loaded".toByteArray())
        assertEquals(listOf(Triple(LogLevel.WARNING, "litert", "GPU accelerator could not be loaded")), received)
    }

    /** Unset crosses as empty, which the native side reads as no key. */
    @Test fun unsetKeyCrossesAsEmpty() {
        assertArrayEquals(ByteArray(0), DesertAntNative.apiKey())
    }

    @Test fun keySetInCodeCrossesTheBridge() {
        DesertAnt.apiKey = "pk_test_code"
        assertEquals("pk_test_code", DesertAntNative.apiKey().decodeToString())
    }
}
