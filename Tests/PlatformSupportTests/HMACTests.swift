import Testing
@testable import PlatformSupport

struct HMACTests {
    @Test func matchesRFC4231() {
        #expect(SHA256.hex(SHA256.hmac(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8)))
            == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    @Test func hashesAKeyLongerThanABlockFirst() {
        let key = [UInt8](repeating: 0xaa, count: 131)
        let message = Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8)
        #expect(SHA256.hex(SHA256.hmac(key: key, message: message))
            == "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
    }
}
