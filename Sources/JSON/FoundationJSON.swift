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
#endif
