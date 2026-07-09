// FIPS 180-4 SHA-256, pure Swift (no Foundation, no swift-crypto/BoringSSL), so
// it works identically on Apple, Linux, Android, and wasm. Model files are
// hashed once on download (not a hot path), so a straightforward streaming
// implementation is the right tradeoff: one algorithm, zero platform seams.

public struct SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private var h: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19)
    private var pending = [UInt8]()   // buffered bytes not yet a full 64-byte block
    private var totalBytes: UInt64 = 0

    public init() { pending.reserveCapacity(64) }

    /// Feed more bytes. Call any number of times before `finalize()`.
    public mutating func update<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        totalBytes &+= UInt64(bytes.count)
        var it = bytes.makeIterator()
        var next = it.next()
        while next != nil {
            while pending.count < 64, let b = next {
                pending.append(b)
                next = it.next()
            }
            if pending.count == 64 {
                processBlock(pending)
                pending.removeAll(keepingCapacity: true)
            }
        }
    }

    /// Finish and return the 32-byte digest. The value is consumed.
    public mutating func finalize() -> [UInt8] {
        let bitLen = totalBytes &* 8
        pending.append(0x80)
        if pending.count > 56 {
            while pending.count < 64 { pending.append(0) }
            processBlock(pending)
            pending.removeAll(keepingCapacity: true)
        }
        while pending.count < 56 { pending.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            pending.append(UInt8(truncatingIfNeeded: bitLen >> UInt64(shift)))
        }
        processBlock(pending)

        var out = [UInt8](); out.reserveCapacity(32)
        for v in [h.0, h.1, h.2, h.3, h.4, h.5, h.6, h.7] {
            out.append(UInt8(truncatingIfNeeded: v >> 24))
            out.append(UInt8(truncatingIfNeeded: v >> 16))
            out.append(UInt8(truncatingIfNeeded: v >> 8))
            out.append(UInt8(truncatingIfNeeded: v))
        }
        return out
    }

    private mutating func processBlock(_ b: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let j = i * 4
            w[i] = UInt32(b[j]) << 24 | UInt32(b[j + 1]) << 16 | UInt32(b[j + 2]) << 8 | UInt32(b[j + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var (a, b2, c, d, e, f, g, hh) = h
        for i in 0..<64 {
            let bigS1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ bigS1 &+ ch &+ Self.k[i] &+ w[i]
            let bigS0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b2) ^ (a & c) ^ (b2 & c)
            let t2 = bigS0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b2; b2 = a; a = t1 &+ t2
        }
        h = (h.0 &+ a, h.1 &+ b2, h.2 &+ c, h.3 &+ d, h.4 &+ e, h.5 &+ f, h.6 &+ g, h.7 &+ hh)
    }

    @inline(__always)
    private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    // MARK: one-shot helpers

    /// The 32-byte SHA-256 digest of `bytes`.
    public static func digest<C: Collection>(_ bytes: C) -> [UInt8] where C.Element == UInt8 {
        var s = SHA256(); s.update(bytes); return s.finalize()
    }

    /// Lowercase hex of a digest (matches Hugging Face's LFS/etag format).
    public static func hex(_ digest: [UInt8]) -> String {
        let d = Array("0123456789abcdef".unicodeScalars)
        var s = ""
        s.unicodeScalars.reserveCapacity(digest.count * 2)
        for b in digest {
            s.unicodeScalars.append(d[Int(b >> 4)])
            s.unicodeScalars.append(d[Int(b & 0xf)])
        }
        return s
    }

    /// Lowercase hex SHA-256 of `bytes` in one call.
    public static func hexDigest<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
        hex(digest(bytes))
    }
}
