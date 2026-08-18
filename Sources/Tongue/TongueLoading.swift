// The loading edge. Everything that touches a file system lives here, so the
// pipeline itself (Tongue.swift, Model.swift, Normalize.swift, Router.swift,
// Hashing.swift) stays free of platform code and cross-compiles as pure Swift.
//
// Matches emo's split: its pipeline takes `metaJSON: String` and `modelBytes:
// [UInt8]`, and a separate Foundation section resolves those from a bundle or a
// downloaded directory.
#if canImport(Foundation)
import Foundation

public extension Tongue {
    /// Load the model bundled with this package. The weights are ~2 MB, small
    /// enough to ship inside the package rather than download.
    init() throws {
        let bundle = Bundle.module
        guard let weightsURL = bundle.url(forResource: "tongue_int8", withExtension: "bin"),
              let metadataURL = bundle.url(forResource: "tongue_meta", withExtension: "json")
        else { throw TongueError.bundledModelMissing }
        try self.init(weightsURL: weightsURL, metadataURL: metadataURL)
    }

    /// Load from explicit file URLs, for an on-demand download or a custom build.
    init(weightsURL: URL, metadataURL: URL) throws {
        let metadataJSON = try String(contentsOf: metadataURL, encoding: .utf8)
        let weightBytes = [UInt8](try Data(contentsOf: weightsURL))
        try self.init(metadataJSON: metadataJSON, weightBytes: weightBytes)
    }

    /// Load `tongue_int8.bin` and `tongue_meta.json` from a directory.
    init(directory: URL) throws {
        try self.init(
            weightsURL: directory.appendingPathComponent("tongue_int8.bin"),
            metadataURL: directory.appendingPathComponent("tongue_meta.json")
        )
    }
}
#endif
