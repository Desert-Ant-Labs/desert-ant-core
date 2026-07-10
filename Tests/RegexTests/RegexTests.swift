import XCTest
import Regex

final class RegexTests: XCTestCase {
    func testStdlibShapedCallSites() throws {
        let re = try regex(#"(\d{4})-(\d{2})"#)
        let text = "date 2026-07 end"
        let m = try XCTUnwrap(text.firstMatch(of: re))   // reads like the stdlib
        XCTAssertEqual(text[m.range], "2026-07")          // Range<String.Index>
        XCTAssertEqual(m[1].substring, "2026")
        XCTAssertEqual(m[2].substring, "07")
        XCTAssertTrue(text.contains(re))
        XCTAssertNil("nope".firstMatch(of: re))
    }

    func testMatchesAndConstants() throws {
        let re = rx(#"\d+"#)                               // trapping, for constants
        XCTAssertEqual(re.matches(in: "a1 b22 c333").map { String($0.substring) }, ["1", "22", "333"])
        XCTAssertEqual("a1 b22".matches(of: re).count, 2)
    }

    func testWholePrefixIgnoresCase() throws {
        let re = try regex(#"a|aa"#)
        XCTAssertNotNil(re.wholeMatch(in: "aa"))           // anchors, so "aa" matches wholly
        XCTAssertNil(re.wholeMatch(in: "aab"))
        XCTAssertNil(try regex(#"\d+"#).wholeMatch(in: "123\n"))
        XCTAssertNotNil(re.prefixMatch(in: "aabbb"))
        XCTAssertNotNil(try regex("abc", ignoresCase: true).firstMatch(in: "xxABCyy"))
    }

    func testUTF16Offsets() throws {
        let text = "🙂 id 123"
        let match = try XCTUnwrap(try Pattern(#"id (\d+)"#).firstUTF16Match(in: text))
        XCTAssertEqual(match.range, 3..<9)
        XCTAssertEqual(match[1].range, 6..<9)
        XCTAssertEqual(match[1].substring, "123")
    }

    func testNonBMPOffsets() throws {
        let re = rx(#"\w+"#)
        let text = "😀 café"
        let m = try XCTUnwrap(text.matches(of: re).last)
        XCTAssertEqual(m.substring, "café")
    }
}
