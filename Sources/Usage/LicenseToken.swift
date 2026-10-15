import JSON

protocol LicenseSignatureVerifier: Sendable {
    func isValidSignature(_ signature: [UInt8], for message: [UInt8], publicKey: [UInt8]) async -> Bool
}

// Kid to uncompressed X9.63 P-256 public key, base64: the keys of events.desertant.com.
let licensePublicKeys: [String: String] = [
    "prod-20261008": "BHkp0y3mP25qGm6pUkD52BxFH9NB2/px8QMf/fPemZH45msFUHbn+pVE0hgJ2QRmuou1QEFQru3zbUTQY2udOp8=",
]

struct LicenseToken {
    struct Header: Decodable {
        var alg: String
        var kid: String
        var typ: String
    }

    struct Payload: Decodable {
        var v: Int
        var lid: String
        var period: String
        var periodEnd: String
        var iat: Int64
    }

    let header: Header
    let payload: Payload
    let signingInput: [UInt8]
    let signature: [UInt8]

    init?(_ token: String) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let headerBytes = base64Decode(parts[0]),
              let payloadBytes = base64Decode(parts[1]),
              let signature = base64Decode(parts[2]),
              let header = try? JSONDecoder().decode(Header.self, from: headerBytes),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadBytes)
        else { return nil }
        self.header = header
        self.payload = payload
        self.signature = signature
        signingInput = Array(parts[0].utf8) + [0x2E] + Array(parts[1].utf8)
    }
}

func verifyLicenseToken(
    _ token: LicenseToken,
    publicKeys: [String: String],
    verifier: (any LicenseSignatureVerifier)?
) async -> Bool {
    guard token.header.alg == "ES256", token.header.typ == "dal-license+jwt",
          token.payload.v == 1, token.signature.count == 64
    else { return false }
    // No verifier on this host (pure Swift on Linux, an insecure web origin): the server verifies at activation.
    guard let verifier else { return true }
    guard let encoded = publicKeys[token.header.kid], let publicKey = base64Decode(encoded) else { return false }
    return await verifier.isValidSignature(token.signature, for: token.signingInput, publicKey: publicKey)
}

package func licenseTokenVerifies(_ token: String, publicKeys: [String: String]) async -> Bool {
    guard let parsed = LicenseToken(token) else { return false }
    return await verifyLicenseToken(parsed, publicKeys: publicKeys, verifier: defaultLicenseVerifier())
}

func base64Decode<Text: StringProtocol>(_ text: Text) -> [UInt8]? {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(text.utf8.count * 3 / 4)
    var buffer: UInt32 = 0
    var bits = 0
    var padded = false
    for char in text.utf8 {
        let value: UInt8
        switch char {
        case 0x41...0x5A: value = char - 0x41
        case 0x61...0x7A: value = char - 0x61 + 26
        case 0x30...0x39: value = char - 0x30 + 52
        case 0x2B, 0x2D: value = 62
        case 0x2F, 0x5F: value = 63
        case 0x3D:
            padded = true
            continue
        default: return nil
        }
        if padded { return nil }
        buffer = ((buffer << 6) | UInt32(value)) & 0xFFFF
        bits += 6
        if bits >= 8 {
            bits -= 8
            bytes.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
        }
    }
    return bits >= 6 ? nil : bytes
}
