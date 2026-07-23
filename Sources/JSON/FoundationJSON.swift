#if canImport(Foundation) && !os(Android) && !os(WASI)
import Foundation

/// Codable JSON decoding on Foundation platforms, wrapping `Foundation.JSONDecoder`
/// so one `import JSON` gives the same `JSONDecoder().decode(_:from:)` API
/// on every platform.
public struct JSONDecoder {
    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try Foundation.JSONDecoder().decode(type, from: Data(json.utf8))
    }

    public func decode<T: Decodable>(_ type: T.Type, from bytes: [UInt8]) throws -> T {
        try Foundation.JSONDecoder().decode(type, from: Data(bytes))
    }
}

/// Codable JSON encoding on Foundation platforms, wrapping `Foundation.JSONEncoder`
/// so one `import JSON` gives the same encoding API on every platform. Output is
/// compact (no whitespace) with object keys sorted, so it is deterministic and
/// byte-identical to the non-Foundation encoder.
public struct JSONEncoder {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> [UInt8] {
        let encoder = Foundation.JSONEncoder()
        encoder.outputFormatting = [.sortedKeys] // deterministic + matches the non-Foundation encoder
        return [UInt8](try encoder.encode(value))
    }

    public func encodeToString<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encode(value), as: UTF8.self)
    }
}
#endif
