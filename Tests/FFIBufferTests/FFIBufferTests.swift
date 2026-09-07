import Testing
@testable import FFIBuffer

struct FFIBufferTests {
    @Test func scalarRoundTrip() {
        var w = FFIWriter()
        w.u32(0x0102_0304)
        w.u64(0xDEAD_BEEF_1234_5678)
        w.f32(1.5)
        w.f64(-3.25)
        w.string("héllo")

        var r = FFIReader(w.bytes)
        #expect(r.u32() == 0x0102_0304)
        #expect(r.u64() == 0xDEAD_BEEF_1234_5678)
        #expect(r.f32() == 1.5)
        #expect(r.f64() == -3.25)
        #expect(r.string() == "héllo")
    }

    @Test func floatArrayRoundTrip() {
        let values: [Float] = [0, 1, -1, 0.333, 1e6, -1e-6]
        var w = FFIWriter()
        w.f32Array(values)
        var r = FFIReader(w.bytes)
        #expect(r.f32Array() == values)
    }

    @Test func lengthPrefixedReaderMatchesEmit() throws {
        var w = FFIWriter()
        w.u32(7)
        w.f32Array([2, 4, 8])
        // ffiEmit prefixes the body with a big-endian u32 length.
        let ptr = try #require(w.emit(), "emit failed")
        defer { ffiFree(ptr) }
        let base = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        let total = 4 + w.bytes.count
        let buffer = [UInt8](UnsafeBufferPointer(start: base, count: total))

        var r = FFIReader(lengthPrefixed: buffer)
        #expect(r.u32() == 7)
        #expect(r.f32Array() == [2, 4, 8])
    }

    @Test func truncatedReadsDegrade() {
        var r = FFIReader([0x00, 0x01])  // too short for a u32
        #expect(r.u32() == 0)  // an underflowing read yields the default, not a partial value
        #expect(r.f32Array() == [])
    }
}
