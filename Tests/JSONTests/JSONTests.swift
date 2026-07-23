import Testing
import JSON

struct JSONTests {
    struct Person: Codable, Equatable {
        let name: String
        let age: Int
        let admin: Bool
        let scores: [Double]
        let nick: String?
    }

    @Test func decodeCodable() throws {
        let text = #"{"name":"Anna","age":33,"admin":true,"scores":[1.5,2],"nick":null}"#
        let p = try JSONDecoder().decode(Person.self, from: text)
        #expect(p == Person(name: "Anna", age: 33, admin: true, scores: [1.5, 2], nick: nil))
    }

    @Test func decodeDictionaryAndBytes() throws {
        struct Labels: Decodable { let id2label: [String: String] }
        let l = try JSONDecoder().decode(Labels.self, from: Array(#"{"id2label":{"0":"O","1":"B-PER"}}"#.utf8))
        #expect(l.id2label["1"] == "B-PER")
    }

    @Test func typeMismatchThrows() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Int.self, from: #""not a number""#)
        }
    }

    @Test func encodeCodableSortedKeysCompact() throws {
        let p = Person(name: "Anna", age: 33, admin: true, scores: [1.5, 2], nick: nil)
        // Object keys are sorted; nil optionals are omitted; output is compact.
        let json = try JSON.JSONEncoder().encodeToString(p)
        #expect(json == #"{"admin":true,"age":33,"name":"Anna","scores":[1.5,2]}"#)
    }

    @Test func encodeRoundTrips() throws {
        let p = Person(name: "Bo", age: 7, admin: false, scores: [3.25], nick: "b")
        let bytes = try JSON.JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Person.self, from: bytes)
        #expect(back == p)
    }

    @Test func encodeEscapesControlChars() throws {
        struct S: Encodable { let s: String }
        let json = try JSON.JSONEncoder().encodeToString(S(s: "a\"b\\c\n"))
        #expect(json == #"{"s":"a\"b\\c\n"}"#)
    }
}
