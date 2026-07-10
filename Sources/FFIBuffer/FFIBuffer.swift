// A self-describing binary buffer for the C ABI between a Swift model core and
// its host language. Results cross as a length-prefixed typed payload rather
// than JSON, so neither side hand-rolls a parser: the host decodes it with its
// own standard library (e.g. java.nio.ByteBuffer on the JVM) and the Swift side
// writes it with `FFIWriter`.
//
// Layout: a big-endian uint32 total length, then the payload. Within the
// payload, integers are big-endian, doubles are IEEE-754 bit patterns, and
// strings are a uint32 UTF-8 byte count followed by the bytes.
//
// Model-agnostic and reusable across projects; the schema of the payload
// (which fields, in what order) is the model's own concern.

#if os(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#endif

/// Accumulates a typed payload, then emits it as a length-prefixed C buffer the
/// host reads and frees with `ffiFree`.
public struct FFIWriter {
    /// The payload built so far (without the outer length prefix).
    public private(set) var bytes: [UInt8] = []

    public init() {}

    /// Append a big-endian uint32 (the low 32 bits of `v`).
    public mutating func u32(_ v: Int) {
        let u = UInt32(truncatingIfNeeded: v)
        bytes.append(UInt8(truncatingIfNeeded: u >> 24))
        bytes.append(UInt8(truncatingIfNeeded: u >> 16))
        bytes.append(UInt8(truncatingIfNeeded: u >> 8))
        bytes.append(UInt8(truncatingIfNeeded: u))
    }

    /// Append a big-endian uint64.
    public mutating func u64(_ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
        }
    }

    /// Append a double as its big-endian IEEE-754 bit pattern.
    public mutating func f64(_ v: Double) { u64(v.bitPattern) }

    /// Append a uint32 UTF-8 byte count, then the UTF-8 bytes.
    public mutating func string(_ s: String) {
        let utf8 = Array(s.utf8)
        u32(utf8.count)
        bytes.append(contentsOf: utf8)
    }

    /// Append raw bytes verbatim (no length prefix).
    public mutating func raw(_ b: [UInt8]) { bytes.append(contentsOf: b) }

    /// Emit the payload as a malloc'd, big-endian uint32 length-prefixed C
    /// buffer. The host reads the length, then the body, and frees it with
    /// `ffiFree`. Returns NULL on allocation failure.
    public func emit() -> UnsafeMutablePointer<CChar>? { ffiEmit(bytes) }
}

/// Prefix `payload` with its big-endian uint32 length into a malloc'd buffer
/// (freed with `ffiFree`). Returns NULL on allocation failure.
public func ffiEmit(_ payload: [UInt8]) -> UnsafeMutablePointer<CChar>? {
    let total = 4 + payload.count
    guard let raw = malloc(total) else { return nil }
    let out = raw.assumingMemoryBound(to: UInt8.self)
    let len = UInt32(payload.count)
    out[0] = UInt8(truncatingIfNeeded: len >> 24)
    out[1] = UInt8(truncatingIfNeeded: len >> 16)
    out[2] = UInt8(truncatingIfNeeded: len >> 8)
    out[3] = UInt8(truncatingIfNeeded: len)
    payload.withUnsafeBufferPointer { src in
        if let base = src.baseAddress { memcpy(out + 4, base, payload.count) }
    }
    return raw.assumingMemoryBound(to: CChar.self)
}

/// Copy a Swift string into a malloc'd, NUL-terminated UTF-8 buffer.
public func ffiCString(_ string: String) -> UnsafeMutablePointer<CChar>? {
    let bytes = Array(string.utf8) + [0]
    guard let raw = malloc(bytes.count) else { return nil }
    _ = bytes.withUnsafeBytes { source in
        memcpy(raw, source.baseAddress!, source.count)
    }
    return raw.assumingMemoryBound(to: CChar.self)
}

/// Free a buffer returned by this module.
public func ffiFree(_ ptr: UnsafeMutablePointer<CChar>?) { free(ptr) }
