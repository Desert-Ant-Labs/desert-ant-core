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

    /// Append a float as its big-endian IEEE-754 bit pattern. `truncatingIfNeeded`
    /// keeps the 32 bits verbatim on wasm32, where `Int` is 32-bit and a plain
    /// `Int(bitPattern)` traps for any pattern with the high bit set.
    public mutating func f32(_ v: Float) { u32(Int(truncatingIfNeeded: v.bitPattern)) }

    /// Append a uint32 element count, then that many big-endian floats. The
    /// portable typed-array payload for audio buffers and feature vectors that
    /// cross the C ABI (host reads it with the matching `FfiReader`).
    public mutating func f32Array(_ values: [Float]) {
        u32(values.count)
        for v in values { f32(v) }
    }

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

/// Reads a payload written by `FFIWriter`, for the other direction: arguments the
/// host passes in. Every read is bounds-checked and returns a default on
/// underflow, so a truncated or malformed buffer yields empty values rather than
/// trapping - the host is untrusted foreign code.
///
/// This is what lets one generic C ABI serve every model: a model's options are
/// a payload it decodes itself, instead of a per-model argument list that would
/// need its own exported symbol.
public struct FFIReader {
    private let bytes: [UInt8]
    private var offset = 0

    /// Read from a payload (no outer length prefix).
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// Read from a host pointer/length pair. NULL or a non-positive length is an
    /// empty payload, which every decoder must treat as "all defaults".
    public init(_ pointer: UnsafePointer<UInt8>?, _ count: Int32) {
        if let pointer, count > 0 {
            self.bytes = Array(UnsafeBufferPointer(start: pointer, count: Int(count)))
        } else {
            self.bytes = []
        }
    }

    /// Read from a length-prefixed buffer as emitted by `ffiEmit` (a big-endian
    /// uint32 length then the body), giving a reader over the body alone. This is
    /// the shape a host hands back from a callback (see AudioIO's HostAudioIO).
    public init(lengthPrefixed buffer: [UInt8]) {
        guard buffer.count >= 4 else { self.init([]); return }
        var length = 0
        for i in 0..<4 { length = (length << 8) | Int(buffer[i]) }
        self.init(Array(buffer[4..<min(buffer.count, 4 + length)]))
    }

    /// Whether anything was supplied at all (an empty payload means defaults).
    public var isEmpty: Bool { bytes.isEmpty }
    /// Whether every byte has been consumed.
    public var isAtEnd: Bool { offset >= bytes.count }
    /// Bytes not yet consumed.
    public var remaining: Int { bytes.count - offset }

    private mutating func take(_ n: Int) -> ArraySlice<UInt8>? {
        guard offset + n <= bytes.count else { offset = bytes.count; return nil }
        defer { offset += n }
        return bytes[offset..<(offset + n)]
    }

    /// Read a big-endian uint32, or 0 on underflow.
    public mutating func u32() -> Int {
        guard let s = take(4) else { return 0 }
        return s.reduce(0) { ($0 << 8) | Int($1) }
    }

    /// Read a big-endian uint64, or 0 on underflow.
    public mutating func u64() -> UInt64 {
        guard let s = take(8) else { return 0 }
        return s.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    /// Read a double from its big-endian IEEE-754 bit pattern, or 0 on underflow.
    public mutating func f64() -> Double { Double(bitPattern: u64()) }

    /// Read a float from its big-endian IEEE-754 bit pattern, or 0 on underflow.
    public mutating func f32() -> Float { Float(bitPattern: UInt32(truncatingIfNeeded: u32())) }

    /// Read a `u32` count followed by that many big-endian floats (audio frames
    /// crossing the FFI boundary). A count larger than the bytes left is a
    /// malformed buffer and yields `[]`.
    public mutating func f32Array() -> [Float] {
        let count = u32()
        guard count > 0, count <= remaining / 4 else { return [] }
        return (0..<count).map { _ in f32() }
    }

    /// Read a length-prefixed UTF-8 string, or "" on underflow.
    public mutating func string() -> String {
        let count = u32()
        guard count > 0, let s = take(count) else { return "" }
        return String(decoding: Array(s))
    }

    /// Read a length-prefixed byte blob, or [] on underflow.
    public mutating func blob() -> [UInt8] {
        let count = u32()
        guard count > 0, let s = take(count) else { return [] }
        return Array(s)
    }

    /// Read a `u32` count followed by that many strings.
    public mutating func strings() -> [String] {
        let count = u32()
        guard count > 0 else { return [] }
        return (0..<count).map { _ in string() }
    }
}

// Foundation-free UTF-8 decoding (this module builds on Android and wasm, where
// Foundation is avoided), replacing invalid sequences rather than failing.
private extension String {
    init(decoding bytes: [UInt8]) {
        self = String(decoding: bytes, as: UTF8.self)
    }
}
