import DesertAnt

// Redact follows the JavaScript/Python reference's UTF-16 indexing. The core
// Regex module owns the platform-independent offset conversion; this adapter
// only preserves the concise names used throughout the pipeline.
typealias PatternMatch = UTF16Match

extension UTF16Match {
    var start: Int { range.lowerBound }
    var end: Int { range.upperBound }

    func range(at index: Int) -> (start: Int, end: Int)? {
        self[index].range.map { ($0.lowerBound, $0.upperBound) }
    }

    func group(_ index: Int) -> String? { self[index].substring.map(String.init) }
}

extension Pattern {
    func allMatches(_ text: String) -> [UTF16Match] { utf16Matches(in: text) }
    func first(_ text: String) -> UTF16Match? { firstUTF16Match(in: text) }
    func test(_ text: String) -> Bool { contains(in: text) }
}
