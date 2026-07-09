#if os(Android) || os(WASI)

/// A parsed JSON value. Internal: the public surface is `JSONDecoder` only.
/// The platform parser (`parseJSONValue`, in HostJSON/JSJSON) produces this;
/// `_JSONDecoder` below drives `Codable` over it, so consumers use the same
/// `JSONDecoder().decode(_:from:)` API as on Foundation platforms.
enum JSONValue {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
}

/// Codable JSON decoding where Foundation is unavailable. Parses with the
/// platform's native JSON, then decodes via the standard-library `Codable`
/// machinery below.
public struct JSONDecoder {
    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try T(from: _JSONDecoder(parseJSONValue(json), codingPath: []))
    }

    public func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        try decode(type, from: String(decoding: bytes, as: UTF8.self))
    }
}

// MARK: - Decoder over JSONValue

private struct _JSONDecoder: Decoder {
    let value: JSONValue
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    init(_ value: JSONValue, codingPath: [CodingKey]) {
        self.value = value
        self.codingPath = codingPath
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let object) = value else { throw expected("a keyed container", codingPath) }
        return KeyedDecodingContainer(KeyedContainer(object, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let array) = value else { throw expected("an unkeyed container", codingPath) }
        return UnkeyedContainer(array, codingPath: codingPath)
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        SingleValueContainer(value, codingPath: codingPath)
    }
}

// MARK: - scalar extraction

private func expected(_ what: String, _ path: [CodingKey]) -> DecodingError {
    DecodingError.typeMismatch(JSONValue.self, .init(codingPath: path, debugDescription: "Expected \(what)"))
}

private func asBool(_ v: JSONValue, _ path: [CodingKey]) throws -> Bool {
    guard case .bool(let b) = v else { throw expected("a boolean", path) }
    return b
}

private func asString(_ v: JSONValue, _ path: [CodingKey]) throws -> String {
    guard case .string(let s) = v else { throw expected("a string", path) }
    return s
}

private func asDouble(_ v: JSONValue, _ path: [CodingKey]) throws -> Double {
    guard case .number(let d) = v else { throw expected("a number", path) }
    return d
}

private func asInteger<I: FixedWidthInteger>(_ v: JSONValue, _ path: [CodingKey]) throws -> I {
    let d = try asDouble(v, path)
    guard let i = I(exactly: d) else {
        throw DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "\(d) is not representable as \(I.self)"))
    }
    return i
}

private func isNull(_ v: JSONValue) -> Bool { if case .null = v { return true } else { return false } }

// MARK: - keyed container

private struct KeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let object: [String: JSONValue]
    let codingPath: [CodingKey]

    init(_ object: [String: JSONValue], codingPath: [CodingKey]) {
        self.object = object
        self.codingPath = codingPath
    }

    var allKeys: [Key] { object.keys.compactMap { Key(stringValue: $0) } }
    func contains(_ key: Key) -> Bool { object[key.stringValue] != nil }

    private func value(for key: Key) throws -> JSONValue {
        guard let v = object[key.stringValue] else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "No value for \"\(key.stringValue)\""))
        }
        return v
    }
    private func path(_ key: Key) -> [CodingKey] { codingPath + [key] }

    func decodeNil(forKey key: Key) throws -> Bool { object[key.stringValue].map(isNull) ?? true }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try asBool(value(for: key), path(key)) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try asString(value(for: key), path(key)) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try asDouble(value(for: key), path(key)) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { Float(try asDouble(value(for: key), path(key))) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try asInteger(value(for: key), path(key)) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try asInteger(value(for: key), path(key)) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try asInteger(value(for: key), path(key)) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try asInteger(value(for: key), path(key)) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try asInteger(value(for: key), path(key)) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try asInteger(value(for: key), path(key)) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try asInteger(value(for: key), path(key)) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try asInteger(value(for: key), path(key)) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try asInteger(value(for: key), path(key)) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try asInteger(value(for: key), path(key)) }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try T(from: _JSONDecoder(value(for: key), codingPath: path(key)))
    }

    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        try _JSONDecoder(value(for: key), codingPath: path(key)).container(keyedBy: type)
    }
    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        try _JSONDecoder(value(for: key), codingPath: path(key)).unkeyedContainer()
    }
    func superDecoder() throws -> Decoder { _JSONDecoder(.object(object), codingPath: codingPath) }
    func superDecoder(forKey key: Key) throws -> Decoder { _JSONDecoder(try value(for: key), codingPath: path(key)) }
}

// MARK: - unkeyed container

private struct UnkeyedContainer: UnkeyedDecodingContainer {
    let array: [JSONValue]
    let codingPath: [CodingKey]
    var currentIndex = 0

    init(_ array: [JSONValue], codingPath: [CodingKey]) {
        self.array = array
        self.codingPath = codingPath
    }

    var count: Int? { array.count }
    var isAtEnd: Bool { currentIndex >= array.count }

    private var path: [CodingKey] { codingPath + [IndexKey(currentIndex)] }
    private mutating func next() throws -> JSONValue {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(JSONValue.self, .init(codingPath: path, debugDescription: "Unkeyed container is at end"))
        }
        defer { currentIndex += 1 }
        return array[currentIndex]
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd, isNull(array[currentIndex]) else { return false }
        currentIndex += 1
        return true
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try asBool(next(), path) }
    mutating func decode(_ type: String.Type) throws -> String { try asString(next(), path) }
    mutating func decode(_ type: Double.Type) throws -> Double { try asDouble(next(), path) }
    mutating func decode(_ type: Float.Type) throws -> Float { Float(try asDouble(next(), path)) }
    mutating func decode(_ type: Int.Type) throws -> Int { try asInteger(next(), path) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try asInteger(next(), path) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try asInteger(next(), path) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try asInteger(next(), path) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try asInteger(next(), path) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try asInteger(next(), path) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try asInteger(next(), path) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try asInteger(next(), path) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try asInteger(next(), path) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try asInteger(next(), path) }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: _JSONDecoder(next(), codingPath: path))
    }

    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        try _JSONDecoder(next(), codingPath: path).container(keyedBy: type)
    }
    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        try _JSONDecoder(next(), codingPath: path).unkeyedContainer()
    }
    mutating func superDecoder() throws -> Decoder { _JSONDecoder(try next(), codingPath: path) }

    private struct IndexKey: CodingKey {
        let intValue: Int?
        let stringValue: String
        init(_ index: Int) { intValue = index; stringValue = "Index \(index)" }
        init?(intValue: Int) { self.intValue = intValue; stringValue = "Index \(intValue)" }
        init?(stringValue: String) { return nil }
    }
}

// MARK: - single value container

private struct SingleValueContainer: SingleValueDecodingContainer {
    let value: JSONValue
    let codingPath: [CodingKey]

    init(_ value: JSONValue, codingPath: [CodingKey]) {
        self.value = value
        self.codingPath = codingPath
    }

    func decodeNil() -> Bool { isNull(value) }
    func decode(_ type: Bool.Type) throws -> Bool { try asBool(value, codingPath) }
    func decode(_ type: String.Type) throws -> String { try asString(value, codingPath) }
    func decode(_ type: Double.Type) throws -> Double { try asDouble(value, codingPath) }
    func decode(_ type: Float.Type) throws -> Float { Float(try asDouble(value, codingPath)) }
    func decode(_ type: Int.Type) throws -> Int { try asInteger(value, codingPath) }
    func decode(_ type: Int8.Type) throws -> Int8 { try asInteger(value, codingPath) }
    func decode(_ type: Int16.Type) throws -> Int16 { try asInteger(value, codingPath) }
    func decode(_ type: Int32.Type) throws -> Int32 { try asInteger(value, codingPath) }
    func decode(_ type: Int64.Type) throws -> Int64 { try asInteger(value, codingPath) }
    func decode(_ type: UInt.Type) throws -> UInt { try asInteger(value, codingPath) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try asInteger(value, codingPath) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try asInteger(value, codingPath) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try asInteger(value, codingPath) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try asInteger(value, codingPath) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: _JSONDecoder(value, codingPath: codingPath))
    }
}
#endif
