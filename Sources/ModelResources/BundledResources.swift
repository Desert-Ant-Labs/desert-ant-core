#if canImport(Foundation) && !os(Android) && !os(WASI)
import Foundation

/// Platform-neutral access to model files in a SwiftPM resource bundle.
/// Foundation and Bundle URL handling stay in this module instead of every
/// model package implementing their own loader.
public struct BundledResources {
    private let bundle: Bundle

    public init(_ bundle: Bundle) {
        self.bundle = bundle
    }

    public func path(named name: String, extension fileExtension: String) throws -> String {
        guard let url = bundle.url(forResource: name, withExtension: fileExtension) else {
            throw BundledResourceError.missing("\(name).\(fileExtension)")
        }
        return url.path
    }

    public func read(named name: String, extension fileExtension: String) throws -> [UInt8] {
        [UInt8](try Data(contentsOf: URL(fileURLWithPath: try path(named: name, extension: fileExtension))))
    }

    public func readString(named name: String, extension fileExtension: String) throws -> String {
        let bytes = try read(named: name, extension: fileExtension)
        guard let string = String(bytes: bytes, encoding: .utf8) else {
            throw BundledResourceError.invalidUTF8("\(name).\(fileExtension)")
        }
        return string
    }

    // Convenience overloads that take a full file name (e.g. "model.onnx"), so
    // callers can use the same names as on a `StoredModel`.
    public func path(_ filename: String) throws -> String {
        let (name, ext) = Self.split(filename)
        return try path(named: name, extension: ext)
    }

    public func read(_ filename: String) throws -> [UInt8] {
        let (name, ext) = Self.split(filename)
        return try read(named: name, extension: ext)
    }

    public func readString(_ filename: String) throws -> String {
        let (name, ext) = Self.split(filename)
        return try readString(named: name, extension: ext)
    }

    private static func split(_ filename: String) -> (name: String, ext: String) {
        guard let dot = filename.lastIndex(of: ".") else { return (filename, "") }
        return (String(filename[..<dot]), String(filename[filename.index(after: dot)...]))
    }
}

public enum BundledResourceError: Error, CustomStringConvertible {
    case missing(String)
    case invalidUTF8(String)

    public var description: String {
        switch self {
        case let .missing(name): "missing bundled resource: \(name)"
        case let .invalidUTF8(name): "bundled resource is not UTF-8: \(name)"
        }
    }
}
#endif
