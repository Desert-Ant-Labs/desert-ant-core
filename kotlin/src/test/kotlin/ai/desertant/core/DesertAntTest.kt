package ai.desertant.core

import ai.desertant.DesertAntNative
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class DesertAntTest {
    @After fun reset() {
        DesertAnt.apiKey = null
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
