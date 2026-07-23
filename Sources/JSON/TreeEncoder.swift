#if os(Android) || os(WASI)

/// Codable JSON encoding where Foundation is unavailable. Drives the standard-
/// library `Codable` machinery into a value tree, then serializes it to compact
/// JSON text (no whitespace, object keys sorted), byte-identical to the
/// Foundation-backed `JSONEncoder` (which uses `.sortedKeys`) on other platforms.
public struct JSONEncoder {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
        [UInt8](try encodeToString(value).utf8)
    }

    public func encodeToString<T: Encodable>(_ value: T) throws -> String {
        let box = EncBox()
        try value.encode(to: _JSONEncoder(codingPath: [], box: box))
        return serialize(box.node)
    }
}

// MARK: - Ordered, reference-boxed value tree

// A boxed slot a container fills in place, so nested containers created up front
// can be populated later (the standard Codable encoding pattern).
private final class EncBox {
    var node: EncValue = .null
}

private final class EncObject {
    var pairs: [(String, EncBox)] = []
    func append(_ key: String, _ box: EncBox) { pairs.append((key, box)) }
}

private final class EncArray {
    var items: [EncBox] = []
}

private enum EncValue {
    case null
    case bool(Bool)
    case string(String)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case object(EncObject)
    case array(EncArray)
}

// MARK: - Encoder

private struct _JSONEncoder: Encoder {
    var codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]
    let box: EncBox

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let object = EncObject()
        box.node = .object(object)
        return KeyedEncodingContainer(KeyedContainer(codingPath: codingPath, object: object))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        let array = EncArray()
        box.node = .array(array)
        return UnkeyedContainer(codingPath: codingPath, array: array)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        SingleValueContainer(codingPath: codingPath, box: box)
    }
}

// MARK: - Keyed

private struct KeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    var codingPath: [CodingKey]
    let object: EncObject

    private func slot(_ key: Key) -> EncBox {
        let box = EncBox()
        object.append(key.stringValue, box)
        return box
    }
    private func set(_ value: EncValue, _ key: Key) { slot(key).node = value }

    mutating func encodeNil(forKey key: Key) throws { set(.null, key) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { set(.bool(value), key) }
    mutating func encode(_ value: String, forKey key: Key) throws { set(.string(value), key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { set(.double(value), key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { set(.double(Double(value)), key) }
    mutating func encode(_ value: Int, forKey key: Key) throws { set(.int(Int64(value)), key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { set(.int(Int64(value)), key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { set(.int(Int64(value)), key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { set(.int(Int64(value)), key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { set(.int(value), key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { set(.uint(UInt64(value)), key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { set(.uint(UInt64(value)), key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { set(.uint(UInt64(value)), key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { set(.uint(UInt64(value)), key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { set(.uint(value), key) }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try value.encode(to: _JSONEncoder(codingPath: codingPath + [key], box: slot(key)))
    }

    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        let object = EncObject()
        slot(key).node = .object(object)
        return KeyedEncodingContainer(KeyedContainer<NestedKey>(codingPath: codingPath + [key], object: object))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let array = EncArray()
        slot(key).node = .array(array)
        return UnkeyedContainer(codingPath: codingPath + [key], array: array)
    }

    mutating func superEncoder() -> Encoder { _JSONEncoder(codingPath: codingPath, box: slot(SuperKey())) }
    mutating func superEncoder(forKey key: Key) -> Encoder { _JSONEncoder(codingPath: codingPath + [key], box: slot(key)) }

    private func slot(_ key: SuperKey) -> EncBox {
        let box = EncBox()
        object.append(key.stringValue, box)
        return box
    }
}

private struct SuperKey: CodingKey {
    var stringValue: String { "super" }
    var intValue: Int? { nil }
    init() {}
    init?(stringValue: String) { nil }
    init?(intValue: Int) { nil }
}

// MARK: - Unkeyed

private struct UnkeyedContainer: UnkeyedEncodingContainer {
    var codingPath: [CodingKey]
    let array: EncArray
    var count: Int { array.items.count }

    private func slot() -> EncBox {
        let box = EncBox()
        array.items.append(box)
        return box
    }
    private func append(_ value: EncValue) { slot().node = value }
    private var indexKey: CodingKey { IndexKey(count) }

    mutating func encodeNil() throws { append(.null) }
    mutating func encode(_ value: Bool) throws { append(.bool(value)) }
    mutating func encode(_ value: String) throws { append(.string(value)) }
    mutating func encode(_ value: Double) throws { append(.double(value)) }
    mutating func encode(_ value: Float) throws { append(.double(Double(value))) }
    mutating func encode(_ value: Int) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: Int8) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: Int16) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: Int32) throws { append(.int(Int64(value))) }
    mutating func encode(_ value: Int64) throws { append(.int(value)) }
    mutating func encode(_ value: UInt) throws { append(.uint(UInt64(value))) }
    mutating func encode(_ value: UInt8) throws { append(.uint(UInt64(value))) }
    mutating func encode(_ value: UInt16) throws { append(.uint(UInt64(value))) }
    mutating func encode(_ value: UInt32) throws { append(.uint(UInt64(value))) }
    mutating func encode(_ value: UInt64) throws { append(.uint(value)) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try value.encode(to: _JSONEncoder(codingPath: codingPath + [indexKey], box: slot()))
    }

    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let object = EncObject()
        slot().node = .object(object)
        return KeyedEncodingContainer(KeyedContainer<NestedKey>(codingPath: codingPath + [indexKey], object: object))
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let inner = EncArray()
        slot().node = .array(inner)
        return UnkeyedContainer(codingPath: codingPath + [indexKey], array: inner)
    }

    mutating func superEncoder() -> Encoder { _JSONEncoder(codingPath: codingPath, box: slot()) }
}

private struct IndexKey: CodingKey {
    let index: Int
    var stringValue: String { String(index) }
    var intValue: Int? { index }
    init(_ index: Int) { self.index = index }
    init?(stringValue: String) { nil }
    init?(intValue: Int) { self.index = intValue }
}

// MARK: - Single value

private struct SingleValueContainer: SingleValueEncodingContainer {
    var codingPath: [CodingKey]
    let box: EncBox

    mutating func encodeNil() throws { box.node = .null }
    mutating func encode(_ value: Bool) throws { box.node = .bool(value) }
    mutating func encode(_ value: String) throws { box.node = .string(value) }
    mutating func encode(_ value: Double) throws { box.node = .double(value) }
    mutating func encode(_ value: Float) throws { box.node = .double(Double(value)) }
    mutating func encode(_ value: Int) throws { box.node = .int(Int64(value)) }
    mutating func encode(_ value: Int8) throws { box.node = .int(Int64(value)) }
    mutating func encode(_ value: Int16) throws { box.node = .int(Int64(value)) }
    mutating func encode(_ value: Int32) throws { box.node = .int(Int64(value)) }
    mutating func encode(_ value: Int64) throws { box.node = .int(value) }
    mutating func encode(_ value: UInt) throws { box.node = .uint(UInt64(value)) }
    mutating func encode(_ value: UInt8) throws { box.node = .uint(UInt64(value)) }
    mutating func encode(_ value: UInt16) throws { box.node = .uint(UInt64(value)) }
    mutating func encode(_ value: UInt32) throws { box.node = .uint(UInt64(value)) }
    mutating func encode(_ value: UInt64) throws { box.node = .uint(value) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try value.encode(to: _JSONEncoder(codingPath: codingPath, box: box))
    }
}

// MARK: - Serialization

private func serialize(_ value: EncValue) -> String {
    switch value {
    case .null: return "null"
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return String(i)
    case .uint(let u): return String(u)
    case .double(let d): return serializeDouble(d)
    case .string(let s): return encodeJSONString(s)
    case .array(let a): return "[" + a.items.map { serialize($0.node) }.joined(separator: ",") + "]"
    case .object(let o):
        let sorted = o.pairs.sorted { $0.0 < $1.0 } // sorted keys, matching Foundation's .sortedKeys
        return "{" + sorted.map { encodeJSONString($0.0) + ":" + serialize($0.1.node) }.joined(separator: ",") + "}"
    }
}

// Emit whole-valued doubles without a fractional part (1.0 -> "1"), matching the
// common JSON representation; other values use the default description.
private func serializeDouble(_ d: Double) -> String {
    if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
    return String(d)
}

private func encodeJSONString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += "\\u" + hex4(scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
    return out
}

private func hex4(_ v: UInt32) -> String {
    let digits = Array("0123456789abcdef".unicodeScalars)
    var out = ""
    for shift in stride(from: 12, through: 0, by: -4) {
        out.unicodeScalars.append(digits[Int((v >> UInt32(shift)) & 0xF)])
    }
    return out
}

#endif
