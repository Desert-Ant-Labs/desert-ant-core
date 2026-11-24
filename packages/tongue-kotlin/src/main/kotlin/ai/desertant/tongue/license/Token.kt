package ai.desertant.tongue.license

import java.security.KeyFactory
import java.security.PublicKey
import java.security.Signature
import java.security.spec.X509EncodedKeySpec

// Kid to uncompressed X9.63 P-256 public key, base64: the keys of events.desertant.com.
internal val licensePublicKeys: Map<String, String> = mapOf(
    "prod-20261008" to "BHkp0y3mP25qGm6pUkD52BxFH9NB2/px8QMf/fPemZH45msFUHbn+pVE0hgJ2QRmuou1QEFQru3zbUTQY2udOp8=",
)

internal class LicenseToken private constructor(
    val alg: String,
    val kid: String,
    val typ: String,
    val version: Long,
    val licenseId: String,
    val period: String,
    val periodEnd: String,
    val issuedAt: Long,
    val signingInput: ByteArray,
    val signature: ByteArray,
) {
    companion object {
        fun parse(token: String): LicenseToken? {
            val parts = token.split('.')
            if (parts.size != 3) return null
            val header = base64Decode(parts[0])?.let { Json.parseObject(it.toString(Charsets.UTF_8)) } ?: return null
            val payload = base64Decode(parts[1])?.let { Json.parseObject(it.toString(Charsets.UTF_8)) } ?: return null
            return LicenseToken(
                alg = header["alg"] as? String ?: return null,
                kid = header["kid"] as? String ?: return null,
                typ = header["typ"] as? String ?: return null,
                version = payload["v"] as? Long ?: return null,
                licenseId = payload["lid"] as? String ?: return null,
                period = payload["period"] as? String ?: return null,
                periodEnd = payload["periodEnd"] as? String ?: return null,
                issuedAt = payload["iat"] as? Long ?: return null,
                signingInput = "${parts[0]}.${parts[1]}".toByteArray(Charsets.UTF_8),
                signature = base64Decode(parts[2]) ?: return null,
            )
        }
    }
}

internal fun verifyLicenseToken(token: LicenseToken, publicKeys: Map<String, String>): Boolean {
    if (token.alg != "ES256" || token.typ != "dal-license+jwt" || token.version != 1L || token.signature.size != 64) {
        return false
    }
    val publicKey = publicKeys[token.kid]?.let(::base64Decode) ?: return false
    return isValidSignature(token.signature, token.signingInput, publicKey)
}

/** The verified token's end in epoch milliseconds, or null when it does not verify. */
internal fun verifiedPeriodEnd(token: String?, publicKeys: Map<String, String>): Pair<LicenseToken, Long>? {
    val parsed = token?.let(LicenseToken::parse) ?: return null
    if (!verifyLicenseToken(parsed, publicKeys)) return null
    return parseISO8601(parsed.periodEnd)?.let { parsed to it }
}

internal fun isValidSignature(signature: ByteArray, message: ByteArray, publicKey: ByteArray): Boolean = try {
    Signature.getInstance("SHA256withECDSA").run {
        initVerify(p256PublicKey(publicKey))
        update(message)
        verify(derSignature(signature))
    }
} catch (_: Exception) {
    false
}

// SubjectPublicKeyInfo up to the point: id-ecPublicKey, prime256v1, then a 66-byte BIT STRING.
private val p256KeyPrefix = byteArrayOf(
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86.toByte(), 0x48, 0xce.toByte(), 0x3d, 0x02, 0x01,
    0x06, 0x08, 0x2a, 0x86.toByte(), 0x48, 0xce.toByte(), 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
)

internal fun p256PublicKey(x963: ByteArray): PublicKey {
    require(x963.size == 65 && x963[0] == 0x04.toByte()) { "not an uncompressed P-256 point" }
    return KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(p256KeyPrefix + x963))
}

internal fun derSignature(raw: ByteArray): ByteArray {
    require(raw.size == 64) { "an ES256 signature is 64 bytes" }
    val r = derInteger(raw.copyOfRange(0, 32))
    val s = derInteger(raw.copyOfRange(32, 64))
    return byteArrayOf(0x30, (r.size + s.size).toByte()) + r + s
}

private fun derInteger(unsigned: ByteArray): ByteArray {
    val trimmed = unsigned.dropWhile { it == 0.toByte() }.toByteArray()
    val body = if (trimmed.isEmpty() || trimmed[0] < 0) byteArrayOf(0) + trimmed else trimmed
    return byteArrayOf(0x02, body.size.toByte()) + body
}

// Both alphabets and optional padding, as the Swift decoder takes them: java.util.Base64 needs API 26.
internal fun base64Decode(text: String): ByteArray? {
    val bytes = java.io.ByteArrayOutputStream(text.length * 3 / 4)
    var buffer = 0
    var bits = 0
    var padded = false
    for (char in text) {
        val value = when (char) {
            in 'A'..'Z' -> char - 'A'
            in 'a'..'z' -> char - 'a' + 26
            in '0'..'9' -> char - '0' + 52
            '+', '-' -> 62
            '/', '_' -> 63
            '=' -> {
                padded = true
                continue
            }
            else -> return null
        }
        if (padded) return null
        buffer = ((buffer shl 6) or value) and 0xFFFF
        bits += 6
        if (bits >= 8) {
            bits -= 8
            bytes.write(buffer shr bits)
        }
    }
    return if (bits >= 6) null else bytes.toByteArray()
}
