import Testing
import Regex

struct RegexTests {
    @Test func stdlibShapedCallSites() throws {
        let re = try regex(#"(\d{4})-(\d{2})"#)
        let text = "date 2026-07 end"
        let m = try #require(text.firstMatch(of: re))   // reads like the stdlib
        #expect(text[m.range] == "2026-07")              // Range<String.Index>
        #expect(m[1].substring == "2026")
        #expect(m[2].substring == "07")
        #expect(text.contains(re))
        #expect("nope".firstMatch(of: re) == nil)
    }

    @Test func matchesAndConstants() throws {
        let re = rx(#"\d+"#)                               // trapping, for constants
        #expect(re.matches(in: "a1 b22 c333").map { String($0.substring) } == ["1", "22", "333"])
        #expect("a1 b22".matches(of: re).count == 2)
    }

    @Test func wholePrefixIgnoresCase() throws {
        let re = try regex(#"a|aa"#)
        #expect(re.wholeMatch(in: "aa") != nil)            // anchors, so "aa" matches wholly
        #expect(re.wholeMatch(in: "aab") == nil)
        #expect(try regex(#"\d+"#).wholeMatch(in: "123\n") == nil)
        #expect(re.prefixMatch(in: "aabbb") != nil)
        #expect(try regex("abc", ignoresCase: true).firstMatch(in: "xxABCyy") != nil)
    }

    @Test func utf16Offsets() throws {
        let text = "🙂 id 123"
        let match = try #require(try Pattern(#"id (\d+)"#).firstUTF16Match(in: text))
        #expect(match.range == 3..<9)
        #expect(match[1].range == 6..<9)
        #expect(match[1].substring == "123")
    }

    @Test func nonBMPOffsets() throws {
        #if !os(WASI) // FIXME: JS RegExp reports UTF-16 offsets, so a non-BMP match truncates
        let re = rx(#"\w+"#)
        let text = "😀 café"
        let m = try #require(text.matches(of: re).last)
        #expect(m.substring == "café")
        #endif
    }
}
