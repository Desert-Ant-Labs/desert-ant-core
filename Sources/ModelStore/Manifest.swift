// The resolved file list for a downloaded model. The manifest is written last,
// so it is both the completion marker and the offline source of truth.
//
// Format (tab-separated, Foundation-free):
//   DAL1
//   R\t<requested path>
//   F\t<resolved path>\t<size>\t<sha256>
//
// Recording the requested paths matters. Two ModelSpecs can point at the same
// repo and revision but request different artifacts. A manifest for one must not
// make the other appear downloaded.

struct Manifest: Equatable {
    struct Entry: Equatable {
        var path: String
        var size: Int64
        var sha256: String
    }

    var requested: [String]
    var entries: [Entry]

    func serialized() -> [UInt8] {
        var lines = ["DAL1"]
        lines += requested.map { "R\t\($0)" }
        lines += entries.map { "F\t\($0.path)\t\($0.size)\t\($0.sha256)" }
        return Array(lines.joined(separator: "\n").utf8)
    }

    static func parse(_ bytes: [UInt8]) -> Manifest? {
        let lines = String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "DAL1" else { return nil }

        var requested: [String] = []
        var entries: [Entry] = []
        for line in lines.dropFirst() where !line.isEmpty {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            switch columns.first {
            case "R" where columns.count == 2:
                requested.append(String(columns[1]))
            case "F" where columns.count == 4:
                guard let size = Int64(columns[2]) else { return nil }
                entries.append(Entry(path: String(columns[1]), size: size, sha256: String(columns[3])))
            default:
                return nil
            }
        }
        return Manifest(requested: requested, entries: entries)
    }
}
