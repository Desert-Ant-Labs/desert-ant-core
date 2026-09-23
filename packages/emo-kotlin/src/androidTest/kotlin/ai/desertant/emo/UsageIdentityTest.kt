package ai.desertant.emo

import ai.desertant.core.HostBridge
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The usage identity an app gets with no wiring of its own: building a model
 * from a Context attaches the package name as the app id and the "desert-ant"
 * SharedPreferences as the store, so the device id minted on the first load is
 * the one every later load reads back. Without that the native side reported
 * app id "unknown" and minted a fresh device id per load.
 */
@RunWith(AndroidJUnit4::class)
class UsageIdentityTest {
    @Test fun deviceIdPersistsAcrossLoadsAndAppIdIsThePackage() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val store = context.getSharedPreferences("desert-ant", Context.MODE_PRIVATE)
        // Start from no id, so the first load has to mint one and persist it
        // rather than pass on an id left behind by an earlier run.
        store.edit().remove(DEVICE_ID_KEY).commit()

        val first = loadAndRun(context)
        assertFalse("the first load persisted no device id", first.isNullOrEmpty())
        val second = loadAndRun(context)
        assertEquals("the second load minted a new device id", first, second)

        assertEquals(context.packageName, HostBridge.applicationId)
        assertEquals(context.packageName, HostBridge.appId().decodeToString())
    }

    /**
     * Building a model reads the device facts for the usage context from the
     * Context, and the bridge hands them to the native side as key=value lines.
     * The test APK may carry no versionName, so appVersion is not required.
     */
    @Test fun loadingAModelSuppliesTheDeviceContext() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        Emo(context).close()

        val facts = HostBridge.deviceContext().decodeToString().lines()
            .filter { it.isNotEmpty() }
            .associate { it.substringBefore('=') to it.substringAfter('=') }
        assertEquals("Android", facts["osName"])
        for (key in listOf("osVersion", "deviceModel", "formFactor", "locale")) {
            assertFalse("no $key in $facts", facts[key].isNullOrEmpty())
        }
        assertTrue(facts["formFactor"] in setOf("mobile", "tablet"))
        assertTrue("an unexpected key in $facts", facts.keys.all {
            it in setOf("appVersion", "osName", "osVersion", "deviceModel", "formFactor", "locale")
        })

        HostBridge.sendsDeviceContext = false
        try {
            assertEquals(0, HostBridge.deviceContext().size)
            assertFalse(ai.desertant.DesertAntNative.sendsDeviceContext())
        } finally {
            HostBridge.sendsDeviceContext = true
        }
    }

    /** Build an Emo, run it once (the device id is resolved on the first run),
     *  release it, and return the device id the store holds afterwards. */
    private fun loadAndRun(context: Context): String? {
        Emo(context).use { emo ->
            runBlocking {
                emo.download()
                emo.suggestions("Pay my bills")
            }
        }
        return context.getSharedPreferences("desert-ant", Context.MODE_PRIVATE)
            .getString(DEVICE_ID_KEY, null)
    }

    private companion object {
        /** Sources/Usage/Storage.swift `deviceIdKey`, shared by every SDK. */
        const val DEVICE_ID_KEY = "ai.desertant.usage.deviceId"
    }
}
