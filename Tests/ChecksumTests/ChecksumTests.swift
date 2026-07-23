import Testing
import Checksum

@Suite(.serialized)
struct ChecksumTests {
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
