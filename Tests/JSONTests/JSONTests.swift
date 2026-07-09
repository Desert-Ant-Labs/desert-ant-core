import XCTest
import JSON

final class JSONTests: XCTestCase {
    struct Person: Codable, Equatable {
        let name: String
        let age: Int
        let admin: Bool
        let scores: [Double]
        let nick: String?
    }

    func testDecodeCodable() throws {
        let text = #"{"name":"Anna","age":33,"admin":true,"scores":[1.5,2],"nick":null}"#
        let p = try JSONDecoder().decode(Person.self, from: text)
        XCTAssertEqual(p, Person(name: "Anna", age: 33, admin: true, scores: [1.5, 2], nick: nil))
    }

    func testDecodeDictionaryAndBytes() throws {
        struct Labels: Decodable { let id2label: [String: String] }
        let l = try JSONDecoder().decode(Labels.self, from: Array(#"{"id2label":{"0":"O","1":"B-PER"}}"#.utf8))
        XCTAssertEqual(l.id2label["1"], "B-PER")
    }

    func testTypeMismatchThrows() {
        XCTAssertThrowsError(try JSONDecoder().decode(Int.self, from: #""not a number""#))
    }
}
