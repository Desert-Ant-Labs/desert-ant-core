package ai.desertant.redact

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Instrumented tests for the Android binding, exercising the real on-device path
 * via JNI: java.util.regex, platform JSON via CHostBridge, system ICU for NFKC,
 * and the static-stdlib runtime. The AAR ships no model, so the suite downloads
 * the pinned revision into the app cache once and reuses it.
 */
@RunWith(AndroidJUnit4::class)
class RedactTest {
    private lateinit var redact: Redact

    @Before fun setUp() {
        redact = Redact(InstrumentationRegistry.getInstrumentation().targetContext)
    }
    // Null-safe: if setUp() throws, an unguarded close() replaces the real
    // failure with UninitializedPropertyAccessException and hides the cause.
    @After fun tearDown() { if (::redact.isInitialized) redact.close() }

    @Test fun redactionEndToEnd() = runTest {
        val r = redact.redaction("Email Anna Kovács at anna@example.hu, IBAN DE89370400440532013000.")
        assertTrue(r.redactedText, Regex("""\[GIVEN_NAME_1\]""").containsMatchIn(r.redactedText))
        assertTrue(Regex("""\[EMAIL_1\]""").containsMatchIn(r.redactedText))
        assertTrue(Regex("""\[BANK_ACCOUNT_1\]""").containsMatchIn(r.redactedText))
        assertEquals("anna@example.hu", r.items.first { it.label == "EMAIL" }.original)
    }

    @Test fun addressesVatImei() = runTest {
        val r = redact.redaction("Ship to 123 Main Street, Apt 4B. VAT DE129273398, IMEI 490154203237518.")
        val got = r.items.map { it.label }.toSet()
        for (l in listOf("BUILDING_NUMBER", "STREET_NAME", "SECONDARY_ADDRESS", "TAX_ID", "IMEI"))
            assertTrue("expected $l in $got", l in got)
    }

    @Test fun restoreRoundTrips() = runTest {
        val text = "Call Dr. Alice Grant on +49 30 1234567."
        val r = redact.redaction(text)
        assertEquals(text, r.restore(r.redactedText))
    }

    @Test fun labelFilter() = runTest {
        val r = redact.redaction("Call +34 600 100 200 or email me@x.com", Options(labels = setOf("PHONE")))
        assertTrue(r.items.all { it.label == "PHONE" })
        assertTrue(r.redactedText.contains("[PHONE_1]"))
        assertTrue(r.redactedText.contains("me@x.com"))
    }

    // On-demand download from the Hub via the Swift ModelStore (host HTTP +
    // POSIX cache), then redact. Network; the model caches under the app cacheDir.
    @Test fun downloadFromHubAndRedact() = runTest {
        val ctx = InstrumentationRegistry.getInstrumentation().targetContext
        val downloaded = Redact(ctx)
        try {
            downloaded.download()
            assertTrue(downloaded.isDownloaded())
            val r = downloaded.redaction("Email Anna Kovács at anna@example.com about the invoice.")
            assertTrue(r.redactedText, Regex("""\[EMAIL_1\]""").containsMatchIn(r.redactedText))
            assertTrue(r.redactedText, Regex("""\[GIVEN_NAME_1\]""").containsMatchIn(r.redactedText))
        } finally {
            downloaded.close()
        }
    }
}
