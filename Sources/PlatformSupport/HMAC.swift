package extension SHA256 {
    /// HMAC-SHA256 of `message` under `key` (RFC 2104).
    static func hmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        let block = 64
        var padded = key.count > block ? digest(key) : key
        padded += [UInt8](repeating: 0, count: block - padded.count)
        let inner = digest(padded.map { $0 ^ 0x36 } + message)
        return digest(padded.map { $0 ^ 0x5c } + inner)
    }
}
