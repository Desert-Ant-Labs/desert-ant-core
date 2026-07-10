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

    /// Read a repo-relative artifact.
    public func read(_ relativePath: String) throws -> [UInt8] {
        try fileSystem.read(path(relativePath))
    }

    /// Read a UTF-8 text artifact.
    public func readString(_ relativePath: String) throws -> String {
        let bytes = try read(relativePath)
        guard let string = String(validating: bytes, as: UTF8.self) else {
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
