import PlatformSupport

/// The install id that licensing sends for an end-user device a host names with a device id.
///
/// The same app and device id always give the same install id, so the device gets one license
/// a month however many processes serve it. With a secret the id is an HMAC-SHA256, which only
/// the holder of the secret can link back to the device id. Without one it is a plain SHA-256,
/// which also covers the API key, so two customers with the same app and device id get two ids.
/// The app is compared as the license server compares it: without case and outer whitespace.
///
/// The id is the first 16 bytes of the hash over the length-prefixed parts, shaped as a version 8 UUID.
func deviceInstallId(deviceId: String, app: String, secret: String?, apiKey: String? = nil) -> String {
    let trimmed = app.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed()
    var parts = ["dal-device-install/v1", String(trimmed).lowercased(), deviceId]
    if secret == nil, let apiKey { parts.append(apiKey) }
    var message: [UInt8] = []
    for part in parts {
        let bytes = Array(part.utf8)
        let count = UInt32(bytes.count)
        message += [UInt8(count >> 24), UInt8(count >> 16 & 0xff), UInt8(count >> 8 & 0xff), UInt8(count & 0xff)]
        message += bytes
    }
    var id = Array((secret.map { SHA256.hmac(key: Array($0.utf8), message: message) } ?? SHA256.digest(message)).prefix(16))
    id[6] = (id[6] & 0x0f) | 0x80
    id[8] = (id[8] & 0x3f) | 0x80
    let hex = Array(SHA256.hex(id))
    return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(hex[$0]) }.joined(separator: "-")
}
