package ai.desertant.emo

import ai.desertant.core.HostBridge
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith

// Building a model from a Context attaches the package name and the "desert-ant" store, so every load licenses one install.
@RunWith(AndroidJUnit4::class)
class InstallIdentityTest {
    @Test fun installIdPersistsAcrossLoadsAndAppIdIsThePackage() {
        val context = ApplicationProvider.getApplicationContext<Context>()

        val first = loadAndRun(context)
        assertFalse("no load persisted an install id", first.isNullOrEmpty())
        val second = loadAndRun(context)
        assertEquals("the second load minted a new install id", first, second)

        assertEquals(context.packageName, HostBridge.applicationId)
        assertEquals(context.packageName, HostBridge.appId().decodeToString())
    }

    // The license client persists the id from a background task, so this waits for it.
    private fun loadAndRun(context: Context): String? {
        Emo(context).use { emo ->
            runBlocking {
                emo.download()
                emo.suggestions("Pay my bills")
            }
        }
        val store = context.getSharedPreferences("desert-ant", Context.MODE_PRIVATE)
        val deadline = System.currentTimeMillis() + 10_000
        while (store.getString(INSTALL_ID_KEY, null).isNullOrEmpty() && System.currentTimeMillis() < deadline) {
            Thread.sleep(50)
        }
        return store.getString(INSTALL_ID_KEY, null)
    }

    private companion object {
        const val INSTALL_ID_KEY = "ai.desertant.usage.deviceId"
    }
}
