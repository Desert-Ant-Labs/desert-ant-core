package ai.desertant.tongue.license

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

// The inputs and the expected ids of Tests/UsageTests/DeviceInstallTests.swift.
class DeviceInstallIdTest {
    private val secret = "0123456789abcdef0123456789abcdef"

    @Test
    fun aSecretGivesTheHmacOfTheAppAndTheDeviceId() {
        assertEquals("683119e6-c29e-877f-bb29-17ea7359b2e2", deviceInstallId("device-7", "server:acme-api", secret))
        assertEquals("18ad7c00-9138-8878-a365-2bb739f64c41", deviceInstallId("dispositivo-ñ-7", "server:acme-api", secret))
    }

    @Test
    fun noSecretGivesThePlainHash() {
        assertEquals("d7af4132-3cfb-8f76-a183-bd33d318ebd0", deviceInstallId("device-7", "server:acme-api", null))
        assertEquals("d7af4132-3cfb-8f76-a183-bd33d318ebd0", deviceInstallId("device-7", "server:acme-api", null, null))
    }

    @Test
    fun anotherDeviceAppOrSecretGivesAnotherId() {
        val base = deviceInstallId("device-7", "server:acme-api", secret)
        assertNotEquals(base, deviceInstallId("device-8", "server:acme-api", secret))
        assertNotEquals(base, deviceInstallId("device-7", "server:other-api", secret))
        assertNotEquals(base, deviceInstallId("device-7", "server:acme-api", secret + "x"))
    }

    @Test
    fun theAppCountsWithoutCaseAndOuterWhitespace() {
        val base = deviceInstallId("device-7", "server:acme-api", secret)
        assertEquals(base, deviceInstallId("device-7", "server:Acme-API", secret))
        assertEquals(base, deviceInstallId("device-7", " server:acme-api\n", secret))
        assertNotEquals(base, deviceInstallId("Device-7", "server:acme-api", secret))
    }

    @Test
    fun theApiKeyCountsOnlyWithoutASecret() {
        val first = deviceInstallId("user-1", "server:node", null, "dal_one")
        assertNotEquals(first, deviceInstallId("user-1", "server:node", null, "dal_two"))
        assertEquals(first, deviceInstallId("user-1", "server:node", null, "dal_one"))
        assertEquals(deviceInstallId("device-7", "server:acme-api", secret), deviceInstallId("device-7", "server:acme-api", secret, "dal_one"))
    }

    @Test
    fun partsDoNotRunTogether() {
        assertNotEquals(deviceInstallId("b", "server:a", secret), deviceInstallId("ab", "server:", secret))
    }
}
