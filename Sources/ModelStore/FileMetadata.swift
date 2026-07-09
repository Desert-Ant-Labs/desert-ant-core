// Per-file sidecar written next to each cached file. Records the verified
// SHA-256 (so a corrupt file can be detected offline, with no network), plus
// the remote size/etag/commit. Stored in a tiny `key=value` line format to stay
// Foundation-free (no JSONEncoder).

struct FileMetadata: Equatable {
    var sha256: String       // lowercase hex of the file we verified and stored
    var size: Int64
    var etag: String?        // server etag at download time (sha256 for LFS files)
    var commit: String?      // resolved commit

    func serialized() -> [UInt8] {
        var s = "sha256=\(sha256)\nsize=\(size)\n"
        if let etag { s += "etag=\(etag)\n" }
        if let commit { s += "commit=\(commit)\n" }
        return Array(s.utf8)
    }

    static func parse(_ bytes: [UInt8]) -> FileMetadata? {
        let text = String(decoding: bytes, as: UTF8.self)
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        guard let sha = fields["sha256"], let sizeStr = fields["size"], let size = Int64(sizeStr) else {
            return nil
        }
        return FileMetadata(sha256: sha, size: size, etag: fields["etag"], commit: fields["commit"])
    }
}
