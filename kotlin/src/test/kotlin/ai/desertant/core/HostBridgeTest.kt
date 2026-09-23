package ai.desertant.core

import android.content.SharedPreferences
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Before
import org.junit.Test

class HostBridgeTest {
    @Before @After fun reset() {
        HostBridge.applicationId = null
        HostBridge.preferences = null
    }

    /** Unattached, the native side reads an empty app id and store, which is
     *  what turned into app.id "unknown" and a fresh device id every load. */
    @Test fun unattachedBridgeHasNoIdentityAndPersistsNothing() {
        assertArrayEquals(ByteArray(0), HostBridge.appId())
        HostBridge.prefsSet(bytes("k"), bytes("v"))
        assertArrayEquals(ByteArray(0), HostBridge.prefsGet(bytes("k")))
    }

    @Test fun attachFillsTheIdentityAndStoreSoValuesRoundTrip() {
        val store = FakePreferences()
        HostBridge.attach("com.example.app") { store }

        assertEquals("com.example.app", HostBridge.appId().decodeToString())
        assertSame(store, HostBridge.preferences)
        HostBridge.prefsSet(bytes("ai.desertant.usage.deviceId"), bytes("device-1"))
        assertEquals("device-1", HostBridge.prefsGet(bytes("ai.desertant.usage.deviceId")).decodeToString())
        assertEquals("device-1", store.values["ai.desertant.usage.deviceId"])
    }

    @Test fun attachKeepsValuesTheHostSetItself() {
        val explicit = FakePreferences()
        HostBridge.applicationId = "host.chosen.key"
        HostBridge.preferences = explicit

        HostBridge.attach("com.example.app") { FakePreferences() }

        assertEquals("host.chosen.key", HostBridge.applicationId)
        assertSame(explicit, HostBridge.preferences)
    }

    /** A second model's attach must not swap the store the first one wrote the
     *  device id into. */
    @Test fun attachingAgainKeepsTheFirstStore() {
        val first = FakePreferences()
        HostBridge.attach("com.example.app") { first }
        HostBridge.prefsSet(bytes("ai.desertant.usage.deviceId"), bytes("device-1"))

        HostBridge.attach("com.example.other") { FakePreferences() }

        assertEquals("com.example.app", HostBridge.applicationId)
        assertSame(first, HostBridge.preferences)
        assertEquals("device-1", HostBridge.prefsGet(bytes("ai.desertant.usage.deviceId")).decodeToString())
    }

    /** Before the first unlock, credential-protected SharedPreferences throw.
     *  The identity is still filled, the model constructor does not fail, and a
     *  later attach supplies the store. */
    @Test fun aStoreThatThrowsIsLeftForALaterAttach() {
        HostBridge.attach("com.example.app") { throw IllegalStateException("locked") }

        assertEquals("com.example.app", HostBridge.applicationId)
        assertNull(HostBridge.preferences)

        val store = FakePreferences()
        HostBridge.attach("com.example.app") { store }
        assertSame(store, HostBridge.preferences)
    }

    /** Once a store is set, later attaches do not open SharedPreferences again. */
    @Test fun aSetStoreIsNotOpenedAgain() {
        HostBridge.attach("com.example.app") { FakePreferences() }
        var opened = 0
        HostBridge.attach("com.example.app") { opened++; FakePreferences() }
        assertEquals(0, opened)
    }

    private fun bytes(s: String) = s.toByteArray(Charsets.UTF_8)
}

/** Enough SharedPreferences for the string get/put the bridge uses. */
private class FakePreferences : SharedPreferences {
    val values = mutableMapOf<String, Any?>()

    override fun getString(key: String?, defValue: String?): String? = values[key] as String? ?: defValue
    override fun getAll(): MutableMap<String, *> = values
    override fun getStringSet(key: String?, defValues: MutableSet<String>?): MutableSet<String>? =
        throw UnsupportedOperationException()
    override fun getInt(key: String?, defValue: Int): Int = throw UnsupportedOperationException()
    override fun getLong(key: String?, defValue: Long): Long = throw UnsupportedOperationException()
    override fun getFloat(key: String?, defValue: Float): Float = throw UnsupportedOperationException()
    override fun getBoolean(key: String?, defValue: Boolean): Boolean = throw UnsupportedOperationException()
    override fun contains(key: String?): Boolean = values.containsKey(key)
    override fun edit(): SharedPreferences.Editor = Editor()
    override fun registerOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?,
    ) = Unit
    override fun unregisterOnSharedPreferenceChangeListener(
        listener: SharedPreferences.OnSharedPreferenceChangeListener?,
    ) = Unit

    private inner class Editor : SharedPreferences.Editor {
        private val pending = mutableMapOf<String, Any?>()

        override fun putString(key: String, value: String?): SharedPreferences.Editor {
            pending[key] = value
            return this
        }
        override fun putStringSet(key: String?, values: MutableSet<String>?) = unsupported()
        override fun putInt(key: String?, value: Int) = unsupported()
        override fun putLong(key: String?, value: Long) = unsupported()
        override fun putFloat(key: String?, value: Float) = unsupported()
        override fun putBoolean(key: String?, value: Boolean) = unsupported()
        override fun remove(key: String): SharedPreferences.Editor {
            pending[key] = null
            return this
        }
        override fun clear() = unsupported()
        override fun commit(): Boolean { apply(); return true }
        override fun apply() {
            for ((key, value) in pending) if (value == null) values.remove(key) else values[key] = value
            pending.clear()
        }

        private fun unsupported(): SharedPreferences.Editor = throw UnsupportedOperationException()
    }
}
