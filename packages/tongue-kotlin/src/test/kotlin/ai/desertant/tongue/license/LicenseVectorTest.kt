package ai.desertant.tongue.license

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LicenseVectorTest {
    private fun verifies(token: String): Boolean =
        LicenseToken.parse(token)?.let { verifyLicenseToken(it, Vectors.publicKeys) } ?: false

    @Test
    fun everyVectorTokenVerifiesOnlyWhenTheVectorSaysValid() {
        val tokens = Vectors.rows("tokens")
        assertEquals(10, tokens.size)
        for (row in tokens) {
            assertEquals(row["expect"] == "valid", verifies(row["token"] as String), row["name"] as String)
        }
    }

    @Test
    fun aValidTokenCarriesItsPayload() {
        val row = Vectors.rows("tokens").first { it["name"] == "valid" }
        val payload = row["payload"] as Map<*, *>
        val token = assertNotNull(LicenseToken.parse(row["token"] as String))
        assertEquals(payload["lid"], token.licenseId)
        assertEquals(payload["period"], token.period)
        assertEquals(payload["periodEnd"], token.periodEnd)
        assertEquals(payload["iat"], token.issuedAt)
        assertEquals("test-2", token.kid)
        assertNull(LicenseToken.parse("not-a-token"))
    }

    @Test
    fun aTokenDoesNotVerifyUnderTheProductionKeys() {
        val valid = Vectors.rows("tokens").first { it["name"] == "valid" }["token"] as String
        assertEquals(false, verifyLicenseToken(LicenseToken.parse(valid)!!, licensePublicKeys))
        assertEquals(65, base64Decode(licensePublicKeys.getValue("prod-20261008"))!!.size)
    }

    @Test
    fun theMintedTestTokenVerifies() {
        assertTrue(verifies(Vectors.mint()))
    }

    @Test
    fun everyResponseRuleGivesItsAction() {
        val rules = Vectors.rows("sdkResponseRules")
        assertTrue(rules.size >= 10)
        for (rule in rules) {
            val body = if (rule["dalErrorBody"] == true) """{"error":"invalid_request","message":"bad"}""" else "<html>Bad Gateway</html>"
            val action = licenseResponseAction((rule["status"] as Long).toInt(), body.toByteArray())
            assertEquals(rule["action"], action.wire, "status ${rule["status"]}, dal body ${rule["dalErrorBody"]}")
        }
    }

    @Test
    fun everyPeriodTimeParses() {
        for (row in Vectors.rows("periods")) {
            for (field in listOf("serverTime", "periodEnd")) {
                val text = row[field] as String
                assertEquals(java.time.Instant.parse(text).toEpochMilli(), parseISO8601(text), text)
            }
        }
        assertNull(parseISO8601("2026-11-07 12:00:00Z"))
        assertNull(parseISO8601("2026-11-07T12:00:00+01:00"))
    }

    @Test
    fun retryTimingFollowsTheSharedRules() {
        assertEquals(LICENSE_MIN_BACKOFF_MS, licenseBackoff(0, null) { it })
        assertEquals(LICENSE_MIN_BACKOFF_MS * 4, licenseBackoff(2, null) { it })
        assertEquals(LICENSE_MAX_BACKOFF_MS, licenseBackoff(40, null) { it })
        assertEquals(120_000, licenseBackoff(0, 120_000) { 0 })
        assertEquals(LICENSE_MAX_BACKOFF_MS, licenseBackoff(0, Long.MAX_VALUE) { 0 })
        assertEquals(30_000, licenseRetryAfter(HttpReply(503, ByteArray(0), " 30 ")))
        assertEquals(LICENSE_MAX_BACKOFF_MS, licenseRetryAfter(HttpReply(503, ByteArray(0), "999999999")))
        assertNull(licenseRetryAfter(HttpReply(503, ByteArray(0), "Wed, 21 Oct 2026 07:28:00 GMT")))
        assertNull(licenseRetryAfter(HttpReply(503, ByteArray(0), "-1")))
        assertNull(licenseRetryAfter(HttpReply(503, ByteArray(0), null)))
    }
}
