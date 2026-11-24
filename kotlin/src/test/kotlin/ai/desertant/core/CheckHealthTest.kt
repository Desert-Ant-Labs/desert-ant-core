package ai.desertant.core

import android.Manifest
import android.app.Application
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** The Context side of the health check: permission lookup and where the messages go. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [24, 37])
class CheckHealthTest {
    private val context: Application get() = RuntimeEnvironment.getApplication()

    @After fun reset() {
        DesertAnt.logger = null
        DesertAnt.configure(apiKey = "")
    }

    private val internetIssue = "The INTERNET permission is missing: models cannot download and licenses cannot be requested."

    @Test fun readsTheInternetPermission() {
        shadowOf(context).denyPermissions(Manifest.permission.INTERNET)
        assertTrue(internetIssue in DesertAnt.checkHealth(context))

        shadowOf(context).grantPermissions(Manifest.permission.INTERNET)
        assertFalse(internetIssue in DesertAnt.checkHealth(context))
    }

    @Test fun readsTheApiKey() {
        val missingKeyIssue = "No API key. Call DesertAnt.configure(apiKey) to send a key with license requests."
        DesertAnt.configure(apiKey = "")
        assertTrue(missingKeyIssue in DesertAnt.checkHealth(context))

        DesertAnt.configure(apiKey = "pk_test_health")
        assertFalse(missingKeyIssue in DesertAnt.checkHealth(context))
    }

    /** Each issue goes to the app's logger as its own warning, whatever the log level. */
    @Test fun logsEveryIssue() {
        DesertAnt.logLevel = LogLevel.OFF
        val logged = mutableListOf<Triple<LogLevel, String, String>>()
        DesertAnt.logger = { level, source, message -> logged.add(Triple(level, source, message)) }
        try {
            val issues = DesertAnt.checkHealth(context)

            assertTrue(issues.isNotEmpty())
            assertEquals(issues.map { Triple(LogLevel.WARNING, "health", it) }, logged)
        } finally {
            DesertAnt.logLevel = LogLevel.WARNING
        }
    }
}
