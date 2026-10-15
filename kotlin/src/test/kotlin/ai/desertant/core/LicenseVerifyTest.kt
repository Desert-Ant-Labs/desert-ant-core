package ai.desertant.core

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.ECGenParameterSpec
import java.util.Base64

class LicenseVerifyTest {
    private val vectors: JsonObject = Json.parseToJsonElement(
        File("../Tests/UsageTests/Resources/license_vectors.json").readText(),
    ).jsonObject

    private val keys: Map<String, ByteArray> = vectors["keys"]!!.jsonArray.associate {
        val key = it.jsonObject
        key["kid"]!!.jsonPrimitive.content to Base64.getDecoder().decode(key["publicKeyX963"]!!.jsonPrimitive.content)
    }

    private class Token(val kid: String, val message: ByteArray, val signature: ByteArray)

    private fun token(name: String): Token {
        val text = vectors["tokens"]!!.jsonArray.map { it.jsonObject }
            .first { it["name"]!!.jsonPrimitive.content == name }["token"]!!.jsonPrimitive.content
        val parts = text.split('.')
        val header = Json.parseToJsonElement(Base64.getUrlDecoder().decode(parts[0]).decodeToString()).jsonObject
        return Token(
            header["kid"]!!.jsonPrimitive.content,
            "${parts[0]}.${parts[1]}".toByteArray(),
            Base64.getUrlDecoder().decode(parts[2]),
        )
    }

    private fun verifies(name: String, kid: String? = null): Boolean {
        val token = token(name)
        return HostBridge.verifyLicense(token.signature, token.message, keys.getValue(kid ?: token.kid))
    }

    @Test fun theValidVectorTokensVerifyUnderTheirKid() {
        assertTrue(verifies("valid"))
        assertTrue(verifies("valid-old-key"))
    }

    @Test fun aBadSignatureATamperedPayloadOrTheOtherKeyDoNotVerify() {
        assertFalse(verifies("bad-signature"))
        assertFalse(verifies("tampered-payload"))
        val valid = token("valid")
        assertFalse(verifies("valid", keys.keys.first { it != valid.kid }))
    }

    @Test fun malformedInputIsRejectedRatherThanThrown() {
        val valid = token("valid")
        val key = keys.getValue(valid.kid)
        assertFalse(HostBridge.verifyLicense(valid.signature.copyOf(63), valid.message, key))
        assertFalse(HostBridge.verifyLicense(token("der-signature").signature, valid.message, key))
        assertFalse(HostBridge.verifyLicense(valid.signature, valid.message, key.copyOfRange(1, 65)))
        assertFalse(HostBridge.verifyLicense(valid.signature, valid.message, ByteArray(65) { if (it == 0) 4 else 1 }))
    }

    @Test fun theKeyBuiltFromTheX963PointIsTheVectorKey() {
        for (key in vectors["keys"]!!.jsonArray.map { it.jsonObject }) {
            val x963 = Base64.getDecoder().decode(key["publicKeyX963"]!!.jsonPrimitive.content)
            val spki = Base64.getDecoder().decode(key["publicKeySpki"]!!.jsonPrimitive.content)
            assertArrayEquals(spki, HostBridge.p256PublicKey(x963).encoded)
        }
    }

    @Test fun theDerSignatureIsWhatTheJdkProduces() {
        val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        repeat(64) { round ->
            val der = Signature.getInstance("SHA256withECDSA").run {
                initSign(pair.private)
                update(byteArrayOf(round.toByte()))
                sign()
            }
            assertArrayEquals(der, HostBridge.derSignature(raw(der)))
        }
    }

    @Test fun derIntegersAreMinimalAndPositive() {
        val highBit = ByteArray(32) { 0xff.toByte() }
        val leadingZeros = ByteArray(32).also { it[31] = 1 }
        val der = HostBridge.derSignature(highBit + leadingZeros)
        assertEquals(0x30, der[0].toInt())
        assertEquals(der.size - 2, der[1].toInt())
        assertArrayEquals(byteArrayOf(0x02, 33, 0) + highBit, der.copyOfRange(2, 37))
        assertArrayEquals(byteArrayOf(0x02, 1, 1), der.copyOfRange(37, 40))
        assertArrayEquals(byteArrayOf(0x30, 6, 0x02, 1, 0, 0x02, 1, 0), HostBridge.derSignature(ByteArray(64)))
    }

    private fun raw(der: ByteArray): ByteArray {
        val rLength = der[3].toInt()
        val r = BigInteger(der.copyOfRange(4, 4 + rLength))
        val s = BigInteger(der.copyOfRange(6 + rLength, der.size))
        return fixed(r) + fixed(s)
    }

    private fun fixed(value: BigInteger): ByteArray {
        val bytes = value.toByteArray().takeLast(32).toByteArray()
        return ByteArray(32 - bytes.size) + bytes
    }
}
