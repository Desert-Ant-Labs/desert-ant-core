#if os(WASI)
import JavaScriptKit

/// Regex engine for WebAssembly: the host JS engine's `RegExp`.
///
/// Flags: always `g` (iteration) + `d` (UTF-16 group indices); `i` when
/// case-insensitive; `u` when the pattern uses `\p{...}` classes.
struct RegexEngine {
    private let regex: JSObject

    init(_ pattern: String, caseInsensitive: Bool) throws {
        var flags = "gd"
        if caseInsensitive { flags += "i" }
        if pattern.contains("\\p{") { flags += "u" }
        regex = JSObject.global.RegExp.function!.new(pattern, flags)
    }

    func matches(in text: String, firstOnly: Bool) -> [[(start: Int, end: Int)?]] {
        regex.lastIndex = 0
        var out: [[(start: Int, end: Int)?]] = []
        while let groups = exec(text) {
            out.append(groups)
            if firstOnly { break }
            if let whole = groups.first ?? nil, whole.start == whole.end {  // avoid empty-match loop
                regex.lastIndex = .number(Double(whole.end + 1))
            }
        }
        return out
    }

    private func exec(_ s: String) -> [(start: Int, end: Int)?]? {
        let m = regex.exec!(s)
        guard let obj = m.object else { return nil }
        let count = Int(obj.length.number ?? 1)
        let indices = obj.indices
        return (0..<count).map { i in
            if let pair = indices.object?[i].object, let a = pair[0].number, let b = pair[1].number {
                return (Int(a), Int(b))
            }
            return nil
        }
    }
}
#endif
