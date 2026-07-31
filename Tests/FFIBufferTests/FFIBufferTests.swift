import XCTest
@testable import FFIBuffer

final class FFIBufferTests: XCTestCase {
    func testScalarRoundTrip() {
        var w = FFIWriter()
        w.u32(0x0102_0304)
        w.u64(0xDEAD_BEEF_1234_5678)
        w.f32(1.5)
        w.f64(-3.25)
        w.string("héllo")

        var r = FFIReader(w.bytes)
        XCTAssertEqual(r.u32(), 0x0102_0304)
        XCTAssertEqual(r.u64(), 0xDEAD_BEEF_1234_5678)
        XCTAssertEqual(r.f32(), 1.5)
        XCTAssertEqual(r.f64(), -3.25)
        XCTAssertEqual(r.string(), "héllo")
    }

    func testFloatArrayRoundTrip() {
        let values: [Float] = [0, 1, -1, 0.333, 1e6, -1e-6]
        var w = FFIWriter()
        w.f32Array(values)
        var r = FFIReader(w.bytes)
        XCTAssertEqual(r.f32Array(), values)
    }

    func testLengthPrefixedReaderMatchesEmit() {
        var w = FFIWriter()
        w.u32(7)
        w.f32Array([2, 4, 8])
        // ffiEmit prefixes the body with a big-endian u32 length.
        guard let ptr = w.emit() else { return XCTFail("emit failed") }
        defer { ffiFree(ptr) }
        let base = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        let total = 4 + w.bytes.count
        let buffer = [UInt8](UnsafeBufferPointer(start: base, count: total))

        var r = FFIReader(lengthPrefixed: buffer)
        XCTAssertEqual(r.u32(), 7)
        XCTAssertEqual(r.f32Array(), [2, 4, 8])
    }

    func testTruncatedReadsDegrade() {
        var r = FFIReader([0x00, 0x01])  // too short for a u32
        XCTAssertEqual(r.u32(), 0)  // an underflowing read yields the default, not a partial value
        XCTAssertEqual(r.f32Array(), [])
    }
}
