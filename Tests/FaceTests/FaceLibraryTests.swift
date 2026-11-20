import Foundation
import Testing
import DesertAnt
import TestSupport
@testable import FaceCore
import JSON
@testable import Face

struct FaceLibraryTests {
    var rng = SplitMix(seed: 42)

    mutating func face(_ person: Int, confidence: Double = 0.9, noise: Double = 0.6) -> DetectedFace {
        var v = [Float](repeating: 0, count: 128)
        v[person] = 1
        for i in 0..<128 { v[i] += Float(rng.gaussian() * noise / Double(128).squareRoot()) }
        return DetectedFace(box: Box(x0: 0.1, y0: 0.1, x1: 0.3, y1: 0.3), landmarks: [], confidence: confidence,
                            faceprint: Faceprint(values: v))
    }

    mutating func library(people: Int, photos: Int) -> FaceLibrary {
        var lib = FaceLibrary()
        for k in 0..<photos { for p in 0..<people { lib.add([face(p)], photo: "p\(p)-\(k)") } }
        lib.regroup()
        return lib
    }

    func personOf(_ lib: FaceLibrary, _ photo: String, _ index: Int = 0) -> Int? {
        lib.face("\(photo)#\(index)")?.person
    }

    @Test mutating func facesAtTheHubAreNoOne() {
        var lib = library(people: 2, photos: 5)
        for k in 0..<12 {
            var v = FaceLibrary.hub.values
            for i in v.indices { v[i] += Float(rng.gaussian() * 0.25 / Double(128).squareRoot()) }
            lib.add([DetectedFace(box: Box(x0: 0.1, y0: 0.1, x1: 0.3, y1: 0.3), landmarks: [], confidence: 0.9,
                                  faceprint: Faceprint(values: v))], photo: "statue-\(k)")
        }
        lib.regroup()
        #expect(lib.people().count == 2)
        #expect((0..<12).allSatisfy { personOf(lib, "statue-\($0)") == nil })

        let id = lib.newPerson(from: "statue-0#0", named: "Statue")!
        lib.confirm("statue-1#0", is: id)
        lib.regroup()
        #expect(lib.people().count == 3)
        #expect(personOf(lib, "statue-1") == id)
    }

    @Test mutating func groupsPeopleAndKeepsTheirIDsAsPhotosArrive() {
        var lib = library(people: 3, photos: 6)
        let people = lib.people()
        #expect(people.count == 3 && people.allSatisfy { $0.photoCount == 6 })
        let ids = (0..<3).map { personOf(lib, "p\($0)-0")! }
        #expect(Set(ids).count == 3)

        lib.add([face(1)], photo: "new")
        #expect(personOf(lib, "new") == ids[1])

        for k in 0..<40 { for p in 0..<4 { lib.add([face(p)], photo: "later\(p)-\(k)") } }
        lib.regroup()
        #expect((0..<3).map { personOf(lib, "p\($0)-0") } == ids)
        #expect(lib.people().count == 4)
        #expect(Set(lib.people().map(\.id)).isSuperset(of: ids))
    }

    @Test mutating func twoFacesOfOnePhotoAreTwoPeople() {
        var lib = FaceLibrary()
        let same = face(0)
        for k in 0..<5 { lib.add([same, same], photo: "twins\(k)") }
        lib.regroup()
        #expect(personOf(lib, "twins0", 0) != personOf(lib, "twins0", 1))
    }

    @Test mutating func unclearFacesDoNotStartPeopleButJoinOnesTheyMatch() {
        var lib = FaceLibrary()
        for k in 0..<6 { lib.add([face(5, confidence: 0.4)], photo: "blur\(k)") }
        lib.regroup()
        #expect(lib.people().isEmpty)

        for k in 0..<5 { lib.add([face(0)], photo: "clear\(k)") }
        lib.add([face(0, confidence: 0.4, noise: 0.3)], photo: "dim")
        lib.regroup()
        let noor = personOf(lib, "clear0")
        #expect(noor != nil && personOf(lib, "dim") == noor)
        #expect(lib.people().count == 1)
        #expect(lib.person(noor!)!.faces.first.map { lib.face($0)!.confidence } == 0.9, "clearest face first")
    }

    /// A few clear statues or cartoons and many unclear ones that match them: no one, until the user names them.
    @Test mutating func aPersonNeedsHalfTheirFacesClear() {
        var lib = library(people: 1, photos: 5)
        for k in 0..<3 { lib.add([face(7, noise: 0.3)], photo: "cartoon\(k)") }
        for k in 0..<6 { lib.add([face(7, confidence: 0.35, noise: 0.3)], photo: "blurred cartoon\(k)") }
        lib.regroup()
        #expect(lib.people().count == 1)
        #expect(personOf(lib, "cartoon0") == nil && personOf(lib, "blurred cartoon0") == nil)

        for k in 3..<6 { lib.add([face(7, noise: 0.3)], photo: "cartoon\(k)") }
        lib.regroup()
        #expect(lib.people().count == 2, "six clear faces of twelve: a person")

        var named = library(people: 1, photos: 5)
        for k in 0..<2 { named.add([face(7, noise: 0.3)], photo: "cartoon\(k)") }
        named.regroup()
        let id = try! #require(personOf(named, "cartoon0"))
        named.name(id, "Mickey")
        for k in 0..<6 { named.add([face(7, confidence: 0.35, noise: 0.3)], photo: "blurred cartoon\(k)") }
        named.regroup()
        #expect(named.person(id)?.faces.count == 8, "a named person keeps the faces that join them")
    }

    /// A face that is a suggestion for someone, turned down, never comes back as one and never joins them.
    @Test mutating func rejectingASuggestionIsForGood() throws {
        var lib = library(people: 1, photos: 6)
        let noor = try #require(personOf(lib, "p0-0"))
        var v = [Float](repeating: 0, count: 128)
        v[0] = 0.46
        v[5] = (1 - 0.46 * 0.46).squareRoot()
        lib.add([DetectedFace(box: Box(x0: 0.1, y0: 0.1, x1: 0.3, y1: 0.3), landmarks: [], confidence: 0.4,
                              faceprint: Faceprint(values: v))], photo: "maybe")
        lib.regroup()
        #expect(lib.suggestions(for: noor) == ["maybe#0"])
        lib.reject("maybe#0", from: noor)
        #expect(lib.suggestions(for: noor).isEmpty)
        #expect(lib.face("maybe#0")?.rejected == [noor] && lib.face("maybe#0")?.person == nil)
        lib.regroup()
        #expect(lib.suggestions(for: noor).isEmpty && lib.face("maybe#0")?.person != noor)
    }

    /// Scanning a photo again keeps what the user said about its faces, and drops it for a face that is now someone else.
    @Test mutating func addingAPhotoAgainKeepsTheUsersDecisions() throws {
        var lib = library(people: 2, photos: 5)
        let a = try #require(personOf(lib, "p0-0")), b = try #require(personOf(lib, "p1-0"))
        let faces = [face(0), face(1)]
        lib.add(faces, photo: "party")
        lib.regroup()
        lib.reject("party#0", from: a)
        lib.confirm("party#1", is: b)
        lib.add(faces, photo: "party")
        #expect(lib.face("party#0")?.rejected == [a])
        #expect(lib.face("party#1")?.person == b && lib.face("party#1")?.confirmed == true)
        lib.add([face(7)], photo: "party")
        #expect(lib.face("party#0")?.rejected == [] && lib.face("party#1") == nil, "another face at #0 starts over")
    }

    /// Faceprints of different embedders, or of different lengths, never group or match together.
    @Test mutating func embeddersNeverMix() throws {
        var lib = FaceLibrary()
        for k in 0..<4 {
            let f = face(0)
            lib.add([f], photo: "new\(k)")
            lib.add([DetectedFace(box: f.box, landmarks: [], confidence: 0.9,
                                  faceprint: Faceprint(values: f.faceprint.values, model: "face-0"))], photo: "old\(k)")
            lib.add([DetectedFace(box: f.box, landmarks: [], confidence: 0.9,
                                  faceprint: Faceprint(values: Array(f.faceprint.values.prefix(64)), model: "face-0"))],
                    photo: "short\(k)")
        }
        lib.regroup()
        let new = try #require(personOf(lib, "new0")), old = try #require(personOf(lib, "old0"))
        let short = try #require(personOf(lib, "short0"))
        #expect(Set([new, old, short]).count == 3)
        #expect(lib.people().count == 3)
        #expect(lib.person(for: face(0).faceprint)?.id == new)
        #expect(lib.suggestions(for: old).allSatisfy { lib.face($0)?.faceprint.model == "face-0" })
    }

    /// A person with confirmed faces of two embedders never gets a second face of a photo they are already in, whatever
    /// embedder that face comes from.
    @Test mutating func aPersonsPhotosHoldAcrossEmbedders() throws {
        var lib = FaceLibrary()
        func old(_ f: DetectedFace) -> DetectedFace {
            DetectedFace(box: f.box, landmarks: [], confidence: f.confidence,
                         faceprint: Faceprint(values: f.faceprint.values, model: "face-0"))
        }
        lib.add([old(face(0, noise: 0.2))], photo: "x")
        lib.add([face(0, noise: 0.2)], photo: "y")
        let made = lib.newPerson(from: "x#0", named: "Noor")
        let noor = try #require(made)
        lib.confirm("y#0", is: noor)
        lib.add(old(face(0, noise: 0.2)), id: "y-old", photo: "y")
        lib.regroup()
        #expect(lib.face("y-old")?.person != noor, "Noor is already in y")
        #expect(lib.face("y#0")?.person == noor && lib.face("x#0")?.person == noor)
    }

    /// A group of faces that keeps an old person's id never includes a face that turned that person down.
    @Test mutating func aRegroupedPersonNeverTakesBackARejectedFace() throws {
        func at(_ cos: Float) -> DetectedFace {
            var v = [Float](repeating: 0, count: 128)
            v[0] = cos
            v[5] = (1 - cos * cos).squareRoot()
            return DetectedFace(box: Box(x0: 0.1, y0: 0.1, x1: 0.3, y1: 0.3), landmarks: [], confidence: 0.9,
                                faceprint: Faceprint(values: v))
        }
        var lib = FaceLibrary()
        for k in 0..<4 { lib.add([face(0, noise: 0.3)], photo: "a\(k)") }
        lib.regroup()
        let p = try #require(personOf(lib, "a0"))
        lib.add([at(0.75)], photo: "b")
        lib.regroup()
        lib.reject("b#0", from: p)
        lib.add([at(1)], photo: "c")
        lib.regroup()
        #expect(personOf(lib, "c") == p && lib.face("c#0")?.confirmed == false)
        for k in 0..<4 { lib.remove(photo: "a\(k)") }
        lib.regroup()
        #expect(personOf(lib, "c") != nil && personOf(lib, "b") == personOf(lib, "c"), "b and c are one group")
        #expect(personOf(lib, "b") != p, "b turned \(p) down")
    }

    /// Rows saved without a unique id, and names saved as "1" and "01", load instead of trapping.
    @Test mutating func repeatedIdsAndNamesLoad() throws {
        let rows = (0..<3).map { k in
            FaceRecord(id: "x#0", photo: "x", confidence: 0.9, faceprint: face(k).faceprint)
        } + [FaceRecord(id: "y#0", photo: "y", confidence: 0.9, faceprint: face(5).faceprint)]
        var lib = FaceLibrary(faces: rows)
        #expect(lib.faces.map(\.id) == ["x#0", "y#0"])
        #expect(lib.face("x#0")?.faceprint == rows[2].faceprint, "the last row with an id wins")
        lib.regroup()
        let json = Data(#"{"faces":[],"names":{"1":"Noor","01":"Ana"}}"#.utf8)
        let decoded = try JSONDecoder().decode(FaceLibrary.self, from: json)
        #expect(decoded.names.count == 1 && ["Noor", "Ana"].contains(decoded.names[1]))
    }

    /// Loading or removing faces never makes the next add regroup the whole library: only faces added since the
    /// last regrouping count toward it.
    @Test mutating func loadingAndRemovingDontCountAsAdding() {
        // Rows never grouped: an automatic regrouping would make a person of them.
        let rows = (0..<40).map { k in FaceRecord(id: "a\(k)#0", photo: "a\(k)", confidence: 0.9, faceprint: face(0).faceprint) }
            + (0..<40).map { k in FaceRecord(id: "s\(k)#0", photo: "s\(k)", confidence: 0.9, faceprint: face(10 + k).faceprint) }
        var lib = FaceLibrary(faces: rows)
        lib.add([face(90)], photo: "new")
        #expect(personOf(lib, "a0") == nil, "a load is not an add")
        lib.remove(photo: "s0")
        lib.add([face(91)], photo: "newer")
        #expect(personOf(lib, "a0") == nil, "a removal is not an add")
        lib.regroup()
        #expect(personOf(lib, "a0") != nil)
    }

    /// A saved row that a later add replaces (a new faceprint, box, date or confidence) is a change to save again.
    @Test mutating func replacedRowsAreChanges() throws {
        var lib = FaceLibrary()
        let first = face(0, noise: 0.1)
        lib.add(first, id: "a", photo: "p")
        lib.add([first], photo: "q")
        _ = lib.takeChanges()
        lib.add(first, id: "a", photo: "p")
        lib.add([first], photo: "q")
        #expect(lib.takeChanges().isEmpty, "the same face again is no change")
        let moved = DetectedFace(box: Box(x0: 0.2, y0: 0.2, x1: 0.4, y1: 0.4), landmarks: [], confidence: 0.8,
                                 faceprint: first.faceprint)
        lib.add(moved, id: "a", photo: "p", date: Date(timeIntervalSince1970: 5))
        lib.add([moved], photo: "q")
        let changed = lib.takeChanges()
        #expect(Set(changed.map(\.id)) == ["a", "q#0"])
        #expect(changed.first { $0.id == "a" }?.confidence == 0.8 && changed.first { $0.id == "a" }?.date == Date(timeIntervalSince1970: 5))
        #expect(lib.takeChanges().isEmpty)
    }

    @Test mutating func namedPeopleKeepTheirFacesAndAreNeverMerged() {
        var lib = library(people: 2, photos: 5)
        let a = personOf(lib, "p0-0")!, b = personOf(lib, "p1-0")!
        lib.name(a, "Noor")
        lib.name(b, "Sam")
        for k in 0..<30 {
            var v = [Float](repeating: 0, count: 128)
            v[0] = 1
            v[1] = 1
            lib.add([DetectedFace(box: Box(x0: 0, y0: 0, x1: 1, y1: 1), landmarks: [], confidence: 0.9,
                                  faceprint: Faceprint(values: v))], photo: "both\(k)")
        }
        lib.regroup()
        #expect(personOf(lib, "p0-0") == a && personOf(lib, "p1-0") == b)
        #expect(lib.person(a)?.name == "Noor" && lib.person(b)?.name == "Sam")
        #expect(lib.people().filter { $0.name != nil }.count == 2)
    }

    @Test mutating func rejectingAFaceIsForGood() {
        var lib = library(people: 1, photos: 6)
        let a = personOf(lib, "p0-0")!
        let wrong = "p0-3#0"
        lib.reject(wrong, from: a)
        #expect(lib.face(wrong)?.person == nil)
        lib.regroup()
        #expect(lib.face(wrong)?.person != a)
        #expect(personOf(lib, "p0-0") == a && lib.person(a)!.photoCount == 5)
        #expect(!lib.suggestions(for: a).contains(wrong))
    }

    @Test mutating func confirmingAFaceIsForGood() {
        var lib = library(people: 2, photos: 5)
        let a = personOf(lib, "p0-0")!
        let odd = "p1-2#0"
        lib.confirm(odd, is: a)
        lib.regroup()
        #expect(lib.face(odd)?.person == a)
    }

    @Test mutating func aNewPersonFromOneFace() throws {
        var lib = library(people: 1, photos: 5)
        let a = personOf(lib, "p0-0")!
        lib.add([face(0), face(4)], photo: "party")
        lib.regroup()
        let stranger = "party#1"
        #expect(lib.face(stranger)?.person == nil, "seen once: no one yet")
        let anaID = lib.newPerson(from: stranger, named: "Ana")
        let ana = try #require(anaID)
        #expect(ana != a && lib.face(stranger)?.person == ana && lib.face(stranger)?.confirmed == true)
        #expect(lib.people().contains { $0.id == ana && $0.name == "Ana" && $0.photoCount == 1 })

        for k in 0..<4 { lib.add([face(4)], photo: "ana\(k)") }
        lib.regroup()
        #expect(lib.person(ana)?.photoCount == 5, "her look-alikes join her")

        let wrong = "p0-2#0"
        let benID = lib.newPerson(from: wrong, named: "Ben")
        let ben = try #require(benID)
        lib.regroup()
        #expect(lib.face(wrong)?.person == ben && lib.face(wrong)?.rejected == [a])
        #expect(lib.person(a)?.photoCount == 5, "five solo photos and the party, less the one that is Ben")
        let none = lib.newPerson(from: "nothing", named: "X")
        #expect(none == nil)
    }

    @Test mutating func mergeJoinsTwoPeopleAndKeepsAName() {
        var lib = library(people: 2, photos: 5)
        let a = personOf(lib, "p0-0")!, b = personOf(lib, "p1-0")!
        lib.name(b, "Sam")
        lib.merge(b, into: a)
        #expect(lib.people().count == 1 && lib.person(a)?.name == "Sam" && lib.person(a)?.photoCount == 10)
        lib.regroup()
        #expect(lib.people().count == 1 && personOf(lib, "p1-0") == a)
    }

    @Test mutating func removingPhotosRemovesPeopleWithNoFacesLeft() {
        var lib = library(people: 2, photos: 3)
        let b = personOf(lib, "p1-0")!
        lib.name(b, "Sam")
        for k in 0..<3 { lib.remove(photo: "p1-\(k)") }
        #expect(lib.person(b) == nil && lib.people().count == 1)
    }

    @Test mutating func prominentPeopleAreSeenOnSeveralDays() {
        var lib = FaceLibrary()
        let day: TimeInterval = 86_400
        for k in 0..<12 {
            lib.add([face(0)], photo: "family\(k)", date: Date(timeIntervalSince1970: Double(k % 4) * day))
            lib.add([face(1)], photo: "guest\(k)", date: Date(timeIntervalSince1970: 10 * day + Double(k) * 60))
            if k < 4 { lib.add([face(2)], photo: "friend\(k)", date: Date(timeIntervalSince1970: Double(k) * day)) }
        }
        lib.regroup()
        #expect(lib.people().count == 3)
        let prominent = lib.people(.prominent)
        #expect(prominent.count == 1 && prominent[0].id == personOf(lib, "family0"))
        lib.name(personOf(lib, "friend0")!, "Ana")
        #expect(lib.people(.prominent).count == 2)
    }

    @Test mutating func whoIsThisAndSuggestions() {
        var lib = library(people: 3, photos: 5)
        let b = personOf(lib, "p1-0")!
        #expect(lib.person(for: face(1).faceprint)?.id == b)
        #expect(lib.person(for: face(7).faceprint) == nil, "a stranger is no one")

        var v = [Float](repeating: 0, count: 128)
        v[1] = 0.5
        v[9] = 0.866
        lib.add([DetectedFace(box: Box(x0: 0, y0: 0, x1: 1, y1: 1), landmarks: [], confidence: 0.9,
                              faceprint: Faceprint(values: v))], photo: "maybe")
        let maybe = "maybe#0"
        #expect(lib.face(maybe)?.person == nil)
        #expect(lib.suggestions(for: b) == [maybe])
        lib.confirm(maybe, is: b)
        #expect(lib.face(maybe)?.person == b && lib.suggestions(for: b).isEmpty)
    }

    @Test mutating func addingAPhotoAgainReplacesItsFaces() {
        var lib = library(people: 1, photos: 4)
        lib.add([face(0), face(3)], photo: "p0-0")
        #expect(lib.face("p0-0#1") != nil)
        lib.add([], photo: "p0-0")
        #expect(lib.face("p0-0#0") == nil && lib.person(personOf(lib, "p0-1")!)!.photoCount == 3)
    }

    @Test mutating func savesAndLoads() throws {
        var lib = library(people: 2, photos: 4)
        let a = personOf(lib, "p0-0")!
        lib.name(a, "Noor")
        lib.reject("p0-1#0", from: a)
        let data = try Foundation.JSONEncoder().encode(lib)
        var back = try Foundation.JSONDecoder().decode(FaceLibrary.self, from: data)
        #expect(back.people() == lib.people())
        back.regroup()
        #expect(back.person(a)?.name == "Noor" && back.face("p0-1#0")?.person != a)
        #expect(data.count < 8 * 1000, "\(data.count) bytes for 8 faces")
    }

    @Test mutating func faceprintsStoreIn512Bytes() throws {
        let f = face(0).faceprint
        #expect(f.data.count == 512)
        #expect(Faceprint(data: f.data, model: f.model) == f)
        #expect(Faceprint(data: Data([1, 2, 3]), model: f.model) == nil)
        let json = try Foundation.JSONEncoder().encode(f)
        #expect(try Foundation.JSONDecoder().decode(Faceprint.self, from: json) == f)
        #expect(json.count < 800)
    }


    @Test mutating func livesInYourOwnDatabase() throws {
        var rows: [String: FaceRecord] = [:]
        var names: [Int: String] = [:]
        var lib = FaceLibrary()
        var n = 0
        for k in 0..<6 {
            for p in 0..<3 {
                lib.add(face(p), id: "row-\(n)", photo: "photo-\(p)-\(k)")
                n += 1
            }
        }
        lib.regroup()
        let first = lib.takeChanges()
        #expect(first.count == 18 && first.allSatisfy { $0.person != nil })
        for r in first { rows[r.id] = r }
        #expect(lib.takeChanges().isEmpty)

        let noor = lib.face("row-0")!.person!
        lib.name(noor, "Noor")
        names = lib.names
        lib.reject("row-3", from: noor)
        let second = lib.takeChanges()
        #expect(second.count == 6, "the five confirmed faces and the rejected one")
        #expect(second.first { $0.id == "row-3" }.map { $0.person == nil && $0.rejected == [noor] } == true)
        for r in second { rows[r.id] = r }

        var back = FaceLibrary(faces: Array(rows.values), names: names)
        #expect(Set(back.people()) == Set(lib.people()))
        #expect(back.takeChanges().isEmpty)
        back.regroup()
        #expect(back.person(noor)?.name == "Noor" && back.face("row-0")?.person == noor && back.face("row-3")?.person != noor)
        for r in back.takeChanges() { rows[r.id] = r }

        back.add(face(0), id: "row-new", photo: "new")
        let added = back.takeChanges()
        #expect(added.map(\.id) == ["row-new"] && added[0].person == noor)
    }

    @Test mutating func facesWithYourIDsUpdateAndRemove() {
        var lib = library(people: 1, photos: 5)
        let a = personOf(lib, "p0-0")!
        lib.name(a, "A")
        lib.add(face(0, confidence: 0.8), id: "p0-0#0", photo: "p0-0")
        #expect(lib.face("p0-0#0")?.person == a && lib.face("p0-0#0")?.confidence == 0.8 && lib.face("p0-0#0")?.confirmed == true)
        lib.remove(face: "p0-0#0")
        #expect(lib.face("p0-0#0") == nil && lib.person(a)?.photoCount == 4)
    }

    @Test mutating func aGonePersonsIDAndNameAreNotReused() throws {
        var lib = library(people: 2, photos: 3)
        let b = personOf(lib, "p1-0")!
        lib.name(b, "Sam")
        for k in 0..<3 { lib.remove(photo: "p1-\(k)") }
        #expect(lib.person(b) == nil)
        var back = try Foundation.JSONDecoder().decode(FaceLibrary.self, from: Foundation.JSONEncoder().encode(lib))
        for k in 0..<20 { back.add([face(7)], photo: "new\(k)") }
        back.regroup()
        let newcomer = try #require(personOf(back, "new0"))
        #expect(newcomer != b && back.person(newcomer)?.name == nil)
    }

    @Test mutating func theSavedFormatIsTheSameOnEveryPlatform() throws {
        // A faceprint stored without base64 padding still reads.
        let print = face(3).faceprint
        let unpadded = Data(#"{"model":"\#(print.model)","data":"\#(print.data.base64EncodedString().replacingOccurrences(of: "=", with: ""))"}"#.utf8)
        #expect(try JSONDecoder().decode(Faceprint.self, from: unpadded) == print)
        var lib = FaceLibrary()
        lib.add(face(0), id: "a", photo: "p", date: Date(timeIntervalSince1970: 1000))
        lib.add(face(0), id: "b", photo: "q")
        lib.regroup()
        let old = try #require(lib.face("a")?.person)
        let created = lib.newPerson(from: "a", named: "Noor")
        let person = try #require(created)
        let json = try JSON.JSONEncoder().encodeToString(lib)
        #expect(json.contains("\"names\":{\"\(person)\":\"Noor\"}"), "\(json.prefix(200))")
        #expect(json.contains("\"date\":1000"))
        #expect(json.contains("\"rejected\":[\(old)]"))
        #expect(json.contains("\"data\":\""))
        let back = try JSON.JSONDecoder().decode(FaceLibrary.self, from: json)
        #expect(back.face("a")?.date == Date(timeIntervalSince1970: 1000) && back.names == [person: "Noor"])
        #expect(back.face("a")?.rejected == [old] && back.face("a")?.faceprint == lib.face("a")?.faceprint)
    }

    @Test mutating func aLargeLibraryStaysFast() {
        var lib = FaceLibrary()
        let start = Date()
        for k in 0..<(FaceTests.scaleTestFaces / 4) { lib.add((0..<4).map { face((k * 4 + $0) % 120) }, photo: "img\(k)") }
        lib.regroup()
        let seconds = Date().timeIntervalSince(start)
        print("FaceLibrary: \(FaceTests.scaleTestFaces) faces added and grouped in \(String(format: "%.1f", seconds)) s")
        #expect(seconds < 60)
        #expect(lib.people().count == 120)
    }
}
