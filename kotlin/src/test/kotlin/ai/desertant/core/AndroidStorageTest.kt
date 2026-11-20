package ai.desertant.core

import android.content.Context
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 37])
class AndroidStorageTest {
    private val context: Context get() = RuntimeEnvironment.getApplication()

    @Before @After fun resetBridge() {
        HostBridge.applicationId = null
        HostBridge.preferences = null
    }

    @Test fun contextAttachesPackageAndTheNamedStore() {
        HostBridge.attach(context)
        val key = "license.\uD83D\uDD11".toByteArray()
        val value = "grant-\u00e9-\u4f60\u597d".toByteArray()
        HostBridge.prefsSet(key, value)

        assertEquals(context.packageName, HostBridge.appId().decodeToString())
        assertEquals(value.decodeToString(), store(context).getString(key.decodeToString(), null))
        assertArrayEquals(value, HostBridge.prefsGet(key))
        assertArrayEquals(byteArrayOf(), HostBridge.prefsGet("missing".toByteArray()))
    }

    @Test fun reattachingAfterClearingBridgeStateReadsTheExistingStore() {
        HostBridge.attach(context)
        HostBridge.prefsSet("install-id".toByteArray(), "install-1".toByteArray())
        // This checks reattachment, not persistence across process death.
        resetBridge()
        HostBridge.attach(context)

        assertEquals("install-1", HostBridge.prefsGet("install-id".toByteArray()).decodeToString())
    }

    @Test fun publicConstructorKeepsHostProvidedIdentityAndStore() {
        val custom = context.getSharedPreferences("host-licenses", Context.MODE_PRIVATE)
        HostBridge.applicationId = "host.chosen.id"
        HostBridge.preferences = custom

        model(context) { _, _, _ ->
            assertEquals("host.chosen.id", HostBridge.applicationId)
            assertSame(custom, HostBridge.preferences)
        }.use {
            HostBridge.prefsSet("license".toByteArray(), "custom".toByteArray())
        }

        assertEquals("custom", custom.getString("license", null))
        assertNull(store(context).getString("license", null))
    }

    @Test fun publicConstructorAttachesBeforeCreatingTheNativeHandle() {
        var creates = 0
        model(context, directory = "/models/local") { modelId, cacheRoot, directory ->
            creates++
            assertEquals(context.packageName, HostBridge.applicationId)
            assertSame(store(context), HostBridge.preferences)
            assertEquals("test-model", modelId.decodeToString())
            assertEquals(context.cacheDir.absolutePath, cacheRoot?.decodeToString())
            assertEquals("/models/local", directory?.decodeToString())
        }.use { assertTrue(it.isDownloaded()) }
        assertEquals(1, creates)
    }

    @Test fun publicConstructorUsesTheDeviceProtectedContextAsPassed() {
        val device = context.createDeviceProtectedStorageContext()
        assertTrue(device.isDeviceProtectedStorage)
        store(context).edit().putString("license", "credential").apply()

        model(device) { _, cacheRoot, _ ->
            assertEquals(device.cacheDir.absolutePath, cacheRoot?.decodeToString())
            assertSame(store(device), HostBridge.preferences)
        }.use { HostBridge.prefsSet("license".toByteArray(), "device".toByteArray()) }

        assertEquals("device", store(device).getString("license", null))
        assertEquals("credential", store(context).getString("license", null))
    }

    @Test fun laterContextDoesNotReplaceTheFirstModelsStore() {
        val device = context.createDeviceProtectedStorageContext()
        model(device).close()
        HostBridge.prefsSet("install-id".toByteArray(), "device-install".toByteArray())
        model(context).close()

        assertSame(store(device), HostBridge.preferences)
        assertEquals("device-install", store(device).getString("install-id", null))
        assertNull(store(context).getString("install-id", null))
    }

    private fun store(context: Context) = context.getSharedPreferences("desert-ant", Context.MODE_PRIVATE)

    private fun model(
        context: Context,
        directory: String? = null,
        onCreate: (ByteArray, ByteArray?, ByteArray?) -> Unit = { _, _, _ -> },
    ) = LoadedModel("test-model", "Test", context, directory, ::IllegalStateException, object : NativeModelApi {
        override fun ensureLoaded() = Unit
        override fun create(modelId: ByteArray, cacheRoot: ByteArray?, directory: ByteArray?): Long {
            onCreate(modelId, cacheRoot, directory)
            return 1L
        }
        override fun destroy(handle: Long) = Unit
        override fun isDownloaded(handle: Long) = 1
        override fun download(handle: Long): Int = error("unexpected download")
        override fun run(handle: Long, input: ByteArray, options: ByteArray?): ByteArray? = error("unexpected inference")
    })
}
