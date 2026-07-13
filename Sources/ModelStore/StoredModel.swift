/// A downloaded model rooted in the store's filesystem.
///
/// This keeps platform filesystem details out of model packages. Consumers can
/// read sidecar files and pass artifact paths to their inference runtime without
/// constructing paths or choosing a filesystem backend themselves.
public struct StoredModel: Sendable {
    public let rootPath: String
    private let fileSystem: FileSystem

    public init(rootPath: String, fileSystem: FileSystem) {
        self.rootPath = rootPath
        self.fileSystem = fileSystem
    }

    /// The platform path for a repo-relative artifact.
    public func path(_ relativePath: String) -> String {
        Self.join(rootPath, relativePath)
    }

    /// Whether a repo-relative file or directory exists.
    public func exists(_ relativePath: String) -> Bool {
        fileSystem.exists(path(relativePath))
    }

    /// Ensure every declared path is present, throwing `localFileMissing`
    /// otherwise. Trailing-slash directory entries are matched as directories.
    public func requireFiles(_ relativePaths: [String]) throws {
        for entry in relativePaths {
            let relativePath = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            guard exists(relativePath) else {
                throw ModelStoreError.localFileMissing(path(relativePath))
            }
        }
    }

    /// Read a repo-relative artifact.
    public func read(_ relativePath: String) throws -> [UInt8] {
        try fileSystem.read(path(relativePath))
    }

    /// Read a UTF-8 text artifact.
    public func readString(_ relativePath: String) throws -> String {
        let bytes = try read(relativePath)
        // `String(validating:as:)` needs macOS 15+, so validate by round-trip
        // (decode replaces invalid sequences, so re-encoding then differs).
        let string = String(decoding: bytes, as: UTF8.self)
        guard Array(string.utf8) == bytes else {
            throw ModelStoreError.io("\(relativePath) is not valid UTF-8")
        }
        return string
    }

    static func join(_ lhs: String, _ rhs: String) -> String {
        guard !lhs.isEmpty else { return rhs }
        guard !rhs.isEmpty else { return lhs }
        return lhs.hasSuffix("/") ? lhs + rhs : lhs + "/" + rhs
    }
}
