#if os(Android)
import CHostBridge

/// Android JSON parser: the host parses with its native JSON and returns a
/// compact binary value tree (see CHostBridge), decoded here into `JSONValue`.
/// No JSON grammar is implemented in Swift.
///
/// Wire tree (after the 4-byte big-endian payload length host_json_parse adds):
///   u8 tag: 0 null, 1 false, 2 true, 3 number(f64), 4 string(u32 len+utf8),
///           5 array(u32 count + nodes), 6 object(u32 count + [u32 keyLen+key, node])
func parseJSONValue(_ text: String) throws -> JSONValue {
    guard let ptr = text.withCString({ host_json_parse($0) }) else { throw JSONError.invalid }
    defer { host_free(ptr) }
    let base = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
    let len = Int(base[0]) << 24 | Int(base[1]) << 16 | Int(base[2]) << 8 | Int(base[3])
    let bytes = [UInt8](UnsafeBufferPointer(start: base + 4, count: len))
    var cursor = 0
    guard let value = decodeNode(bytes, &cursor) else { throw JSONError.invalid }
    return value
}

enum JSONError: Error { case invalid }

private func readU32(_ b: [UInt8], _ c: inout Int) -> Int? {
    guard c + 4 <= b.count else { return nil }
    let v = Int(b[c]) << 24 | Int(b[c + 1]) << 16 | Int(b[c + 2]) << 8 | Int(b[c + 3])
    c += 4
    return v
}

private func readString(_ b: [UInt8], _ c: inout Int) -> String? {
    guard let n = readU32(b, &c), c + n <= b.count else { return nil }
    let s = String(decoding: b[c..<c + n], as: UTF8.self)
    c += n
    return s
}

private func decodeNode(_ b: [UInt8], _ c: inout Int) -> JSONValue? {
    guard c < b.count else { return nil }
    let tag = b[c]; c += 1
    switch tag {
    case 0: return .null
    case 1: return .bool(false)
    case 2: return .bool(true)
    case 3:
        guard c + 8 <= b.count else { return nil }
        var bits: UInt64 = 0
        for i in 0..<8 { bits = bits << 8 | UInt64(b[c + i]) }
        c += 8
        return .number(Double(bitPattern: bits))
    case 4:
        return readString(b, &c).map(JSONValue.string)
    case 5:
        guard let n = readU32(b, &c) else { return nil }
        var out: [JSONValue] = []
        out.reserveCapacity(n)
        for _ in 0..<n { guard let v = decodeNode(b, &c) else { return nil }; out.append(v) }
        return .array(out)
    case 6:
        guard let n = readU32(b, &c) else { return nil }
        var out: [String: JSONValue] = [:]
        for _ in 0..<n {
            guard let key = readString(b, &c), let v = decodeNode(b, &c) else { return nil }
            out[key] = v
        }
        return .object(out)
    default:
        return nil
    }
}
#endif
