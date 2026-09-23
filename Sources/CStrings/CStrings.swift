// NUL-terminated C string decoding, shared by every module that crosses a C
// boundary. String(cString:) is deprecated in newer SDKs in favor of decoding the
// bytes without the terminator. No dependencies, so any module can link it.

/// Decode a NUL-terminated UTF-8 C string, truncating the terminator.
public func decodeCString(_ pointer: UnsafePointer<CChar>) -> String {
    String(decoding: cStringBytes(pointer), as: UTF8.self)
}

/// The same decode for a stack buffer (e.g. a C error buffer).
public func decodeCString(_ buffer: [CChar]) -> String {
    buffer.withUnsafeBufferPointer { decodeCString($0.baseAddress!) }
}

/// The UTF-8 bytes of a NUL-terminated C string, without the terminator, for
/// callers that marshal bytes onward rather than building a String.
public func cStringBytes(_ pointer: UnsafePointer<CChar>) -> [UInt8] {
    var length = 0
    while pointer[length] != 0 { length += 1 }
    return Array(UnsafeRawBufferPointer(start: pointer, count: length))
}
