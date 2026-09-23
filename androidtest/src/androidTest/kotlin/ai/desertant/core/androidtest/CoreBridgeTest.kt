package ai.desertant.core.androidtest

import ai.desertant.DesertAntNative
import ai.desertant.core.HostBridge
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith

/**
 * On-device (Tier 2a) integration test: drives the Swift core's host-backed
 * paths through JNI with the real Android host (java.util.regex + the platform
 * JSON parser installed via DesertAntNative, the host class every SDK installs).
 * An empty result means every check passed on the device/emulator.
 *
 * The bridge installs once per process, so both tests pass the same class.
 */
@RunWith(AndroidJUnit4::class)
class CoreBridgeTest {
    @Test
    fun hostBackedPathsWork() {
        assertEquals("", CoreBridge.runChecks(DesertAntNative::class.java))
    }

    /**
     * The facts Kotlin reads reach the context the Swift client sends, and the
     * Kotlin opt-out reaches the Swift one: with it on, not even osName goes,
     * which emptying the facts alone would still have sent.
     */
    @Test
    fun theUsageContextCarriesTheDeviceFactsAndHonoursTheOptOut() {
        HostBridge.attach(InstrumentationRegistry.getInstrumentation().targetContext)

        val context = CoreBridge.usageContext(DesertAntNative::class.java).lines()
            .filter { it.isNotEmpty() }
            .associate { it.substringBefore('=') to it.substringAfter('=') }
        assertEquals("Android", context["osName"])
        for (key in listOf("osVersion", "deviceModel", "formFactor", "locale")) {
            assertFalse("no $key in $context", context[key].isNullOrEmpty())
        }

        HostBridge.sendsDeviceContext = false
        try {
            assertEquals("", CoreBridge.usageContext(DesertAntNative::class.java))
        } finally {
            HostBridge.sendsDeviceContext = true
        }
    }
}
