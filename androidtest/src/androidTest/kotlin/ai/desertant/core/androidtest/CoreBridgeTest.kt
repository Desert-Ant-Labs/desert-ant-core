package ai.desertant.core.androidtest

import ai.desertant.core.HostBridge
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

/**
 * On-device (Tier 2a) integration test: drives the Swift core's host-backed
 * paths through JNI with the real Android host (java.util.regex + the platform
 * JSON parser installed via HostBridge). An empty result means every check
 * passed on the device/emulator.
 */
@RunWith(AndroidJUnit4::class)
class CoreBridgeTest {
    @Test
    fun hostBackedPathsWork() {
        assertEquals("", CoreBridge.runChecks(HostBridge::class.java))
    }
}
