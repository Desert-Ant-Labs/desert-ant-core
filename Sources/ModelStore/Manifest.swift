// The resolved file list for a downloaded model, written once all files are
// present and verified. It is the completion marker AND the offline source of
// truth: `isDownloaded` reads it to know exactly which files make up the model
// (folders already expanded) and the verified SHA-256 to check each against.
//
// One `path\tsize\tsha256` line per file. Foundation-free (no JSON encoder).

struct Manifest: Equatable {
    struct Entry: Equatable {
        var path: String
        var size: Int64
        var sha256: String   // the content hash we verified and stored
    }
    var entries: [Entry]

    func serialized() -> [UInt8] {
        Array(entries.map { "\($0.path)\t\($0.size)\t\($0.sha256)" }.joined(separator: "\n").utf8)
    }

    static func parse(_ bytes: [UInt8]) -> Manifest? {
        let text = String(decoding: bytes, as: UTF8.self)
        var out: [Entry] = []
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count == 3, let size = Int64(cols[1]) else { return nil }
            out.append(Entry(path: String(cols[0]), size: size, sha256: String(cols[2])))
        }
        return Manifest(entries: out)
    }
}
