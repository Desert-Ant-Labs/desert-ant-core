import Testing
@testable import ModelStore

@Suite(.serialized)
struct SHA256Tests {
    private func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test func knownVectors() {
        // FIPS 180-4 / standard SHA-256 test vectors.
        #expect(SHA256.hexDigest(bytes("")) ==
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256.hexDigest(bytes("abc")) ==
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SHA256.hexDigest(bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")) ==
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test func streamingMatchesOneShot() {
        // A block-boundary-crossing input hashed in odd chunks == one-shot.
        var data = [UInt8](); for i in 0..<1000 { data.append(UInt8(i & 0xff)) }
        let oneShot = SHA256.hexDigest(data)

        var s = SHA256()
        var i = 0
        for chunk in [1, 63, 64, 65, 100, 700, 6] {  // sums to 999; last byte separately
            s.update(data[i..<min(i + chunk, data.count)])
            i += chunk
        }
        s.update(data[i...])
        #expect(SHA256.hex(s.finalize()) == oneShot)
    }

    @Test func largeInput() {
        // isDownloaded re-hashes every file on every call, so exercise a
        // model-sized buffer: correct length and deterministic. (No wall-clock
        // timing assertion: Swift Testing runs tests in parallel, so elapsed
        // wall time reflects scheduler contention, not hashing work.)
        let data = [UInt8](repeating: 0x5a, count: 16 * 1024 * 1024)
        let a = SHA256.hexDigest(data)
        #expect(a.count == 64)
        #expect(a == SHA256.hexDigest(data))
    }

    @Test func millionA() {
        // Classic 1,000,000 'a' vector, exercises many blocks + length encoding.
        var s = SHA256()
        let chunk = [UInt8](repeating: 0x61, count: 1000)
        for _ in 0..<1000 { s.update(chunk) }
        #expect(SHA256.hex(s.finalize()) ==
                "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
}

/// `SHA256` is CryptoKit on Apple platforms, CNG on Windows, and
/// `SoftwareSHA256` elsewhere.
/// The software loop still ships (Linux, Android, wasm), so it must keep
/// agreeing with whatever the public type resolves to on this platform.
@Suite struct SHA256BackendTests {
    private func pseudoRandom(_ count: Int) -> [UInt8] {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        return (0..<count).map { _ -> UInt8 in
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: seed >> 33)
        }
    }

    @Test func softwareAndPublicImplementationsAgree() {
        // Padding boundaries (55/56/63/64/65) and a multi-chunk input.
        for size in [0, 1, 55, 56, 63, 64, 65, 1000, 1 << 20] {
            let data = pseudoRandom(size)
            var soft = SoftwareSHA256()
            soft.update(data)
            #expect(SHA256.hex(soft.finalize()) == SHA256.hexDigest(data), "differs at \(size) bytes")
        }
    }

    @Test func publicTypeHashesNonContiguousInput() {
        // A lazy view has no contiguous storage, so it takes the copying path.
        let data = pseudoRandom(500)
        let lazyView = data.lazy.map { $0 }
        #expect(SHA256.hexDigest(lazyView) == SHA256.hexDigest(data))
    }

    @Test func copiedHasherIsIndependent() {
        // The Windows backend shares one CNG handle between copies until a
        // write, so a copy that diverges must not disturb the original.
        let data = pseudoRandom(200)
        var a = SHA256()
        a.update(data[0..<100])
        var b = a
        b.update([0xFF])
        a.update(data[100...])
        #expect(SHA256.hex(a.finalize()) == SHA256.hexDigest(data))
        #expect(SHA256.hex(b.finalize()) == SHA256.hexDigest(data[0..<100] + [0xFF]))
    }

    @Test func publicTypeHashesArraySlices() {
        let data = pseudoRandom(300)
        #expect(SHA256.hexDigest(data[10..<200]) == SHA256.hexDigest(Array(data[10..<200])))
    }
}
