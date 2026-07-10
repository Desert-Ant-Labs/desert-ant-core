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
