#if os(Android)
// Do not import Foundation on Android: it pulls in the full ICU payload.
// Use FoundationEssentials to keep ICU out of the SDK.
import FoundationEssentials
#else
import Foundation
#endif

/// One face in a ``FaceLibrary``: what ``Face`` found, and what the library and
/// the user decided about it. Every field is a plain value, so a record maps to
/// one row of your own faces table.
public struct FaceRecord: Sendable, Hashable, Codable, Identifiable {
    /// Your id for the face, unique in the library.
    public var id: String
    /// Your id for its photo: an asset id, a file name, a video frame.
    public var photo: String
    /// When the photo was taken, if known.
    public var date: Date?
    /// Where the face is in its photo, for thumbnails.
    public var box: Box?
    public var confidence: Double
    public var faceprint: Faceprint
    /// The person the face is with, if any.
    public var person: Int?
    /// The user said this face is ``person``, so the face stays with that person.
    public var confirmed: Bool
    /// The people the user said this face is not.
    public var rejected: Set<Int>

    private enum CodingKeys: String, CodingKey { case id, photo, date, box, confidence, faceprint, person, confirmed, rejected }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        photo = try c.decode(String.self, forKey: .photo)
        date = try c.decodeIfPresent(Double.self, forKey: .date).map { Date(timeIntervalSince1970: $0) }
        box = try c.decodeIfPresent(Box.self, forKey: .box)
        confidence = try c.decode(Double.self, forKey: .confidence)
        faceprint = try c.decode(Faceprint.self, forKey: .faceprint)
        person = try c.decodeIfPresent(Int.self, forKey: .person)
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? false
        rejected = Set(try c.decodeIfPresent([Int].self, forKey: .rejected) ?? [])
    }

    /// Encoded with `date` as seconds since 1970 and `rejected` sorted, the same bytes on every platform.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(photo, forKey: .photo)
        try c.encodeIfPresent(date?.timeIntervalSince1970, forKey: .date)
        try c.encodeIfPresent(box, forKey: .box)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(faceprint, forKey: .faceprint)
        try c.encodeIfPresent(person, forKey: .person)
        try c.encode(confirmed, forKey: .confirmed)
        try c.encode(rejected.sorted(), forKey: .rejected)
    }

    public init(id: String, photo: String, date: Date? = nil, box: Box? = nil, confidence: Double, faceprint: Faceprint,
                person: Int? = nil, confirmed: Bool = false, rejected: Set<Int> = []) {
        self.id = id
        self.photo = photo
        self.date = date
        self.box = box
        self.confidence = confidence
        self.faceprint = faceprint
        self.person = person
        self.confirmed = confirmed
        self.rejected = rejected
    }
}

/// The people in a set of photos, for a people view where the user sees, names
/// and fixes faces. `FaceLibrary` groups faces into people, keeps the groups
/// right as photos come and go, and keeps every correction the user makes.
/// `FaceLibrary` runs without the model, on the faces ``Face`` found.
///
/// ```swift
/// var library = FaceLibrary()
/// library.add(try await face.faces(in: image), photo: asset.id, date: asset.date)
///
/// for person in library.people(.prominent) {
///     show(person.name, library.face(person.keyFace)?.box)
/// }
/// library.name(person.id, "Noor")
/// library.confirm(faceID, is: person.id)        // "This is Noor"
/// library.reject(faceID, from: person.id)       // "This is not Noor"
/// library.merge(other.id, into: person.id)      // "These are the same person"
/// library.person(for: newFace.faceprint)?.name  // "Noor"
/// ```
///
/// The library's state is ``faces`` and ``names``. Save the library as JSON
/// (`FaceLibrary` is `Codable`), or keep both in your own database: write the
/// rows ``takeChanges()`` gives you, and rebuild with ``init(faces:names:)``.
///
/// Blurred, dark and turned-away faces (low ``DetectedFace/confidence``) don't
/// start or bridge groups; those faces join a person only when they clearly match,
/// and a person needs at least half their faces clear.
/// The library never puts two faces of one photo in one person. A person the user
/// named, merged or fixed keeps those faces through every regrouping, and the
/// library never merges two named people.
public struct FaceLibrary: Sendable, Codable {
    /// A person in the library.
    public struct Person: Sendable, Hashable, Identifiable, Codable {
        /// Stable while the person exists: across adds, removals and regrouping.
        public let id: Int
        /// The name the user gave, if any.
        public let name: String?
        /// Their faces' ids, the clearest first.
        public let faces: [String]
        /// How many photos they are in.
        public let photoCount: Int
        /// The face to show for them: their clearest.
        public var keyFace: String { faces[0] }
    }

    /// Which people ``people(_:)`` lists.
    public enum Filter: Sendable {
        /// Everyone seen in at least two photos, and every named person.
        case all
        /// The people that matter to the user: everyone named, and anyone in at
        /// least 10 photos taken on at least 3 different days (when photos have
        /// dates). The filter lists family and leaves out a guest seen across one wedding.
        case prominent
    }

    /// Every face, in the order added.
    public private(set) var faces: [FaceRecord] = []
    /// The names the user gave, by person id.
    public private(set) var names: [Int: String] = [:]

    private var index: [String: Int] = [:]
    private var photoFaces: [String: Int] = [:]
    private var nextPerson = 1
    private var addedSinceGrouping = 0
    private var reported: [String: Decision] = [:]
    private var sums: [SumKey: (sum: [Float], photos: Set<String>)]? = nil

    public init() {}

    /// A library from your own rows and names, as saved. The library doesn't regroup on load, and faces it
    /// loads don't count toward the next automatic regrouping: call `regroup()` for rows never grouped. Of rows
    /// that share an id, the last one is kept.
    public init(faces: [FaceRecord], names: [Int: String] = [:]) {
        // Rows saved without a unique id: the last row with an id wins, in the place of the first.
        var at: [String: Int] = [:]
        var unique: [FaceRecord] = []
        for f in faces {
            if let i = at[f.id] { unique[i] = f } else {
                at[f.id] = unique.count
                unique.append(f)
            }
        }
        self.faces = unique
        self.names = names
        settle()
    }

    private enum CodingKeys: String, CodingKey { case faces, names }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let names = try c.decode([String: String].self, forKey: .names)
        self.init(faces: try c.decode([FaceRecord].self, forKey: .faces),
                  names: Dictionary(names.compactMap { k, v in Int(k).map { ($0, v) } }) { first, _ in first })
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(faces, forKey: .faces)
        try c.encode(Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) }), forKey: .names)
    }

    /// Adds a photo's faces, replacing any the library has for `photo`. Their ids
    /// are `"<photo>#<index>"`. A face the library already had for `photo` keeps its
    /// person, confirmation and rejections when it is found again.
    public mutating func add(_ faces: [DetectedFace], photo: String, date: Date? = nil) {
        let new = faces.enumerated().map { record($0.element, id: "\(photo)#\($0.offset)", photo: photo, date: date) }
        // A face found again (same id, a faceprint that still matches) keeps what the user said about it.
        let same = Set(new.filter { r in
            index[r.id].map { self.faces[$0].photo == photo && self.faces[$0].faceprint.isSamePerson(as: r.faceprint, .strict) } ?? false
        }.map(\.id))
        removeFaces { $0.photo == photo && !same.contains($0.id) }
        insert(new)
    }

    /// Adds one face with your own id. If the library has a face with that id, the
    /// new face replaces it, and what the user said about the face stays.
    public mutating func add(_ face: DetectedFace, id: String, photo: String, date: Date? = nil) {
        insert([record(face, id: id, photo: photo, date: date)])
    }

    /// Removes a photo and its faces.
    public mutating func remove(photo: String) {
        guard (photoFaces[photo] ?? 0) > 0 else { return }
        removeFaces { $0.photo == photo }
    }

    /// Removes one face.
    public mutating func remove(face id: String) {
        removeFaces { $0.id == id }
    }

    /// The people, most photographed first.
    public func people(_ filter: Filter = .all) -> [Person] {
        var byPerson: [Int: [FaceRecord]] = [:]
        for f in faces { if let p = f.person { byPerson[p, default: []].append(f) } }
        return byPerson.compactMap { id, fs -> Person? in
            let person = Self.person(id, fs, names[id])
            if person.name != nil { return person }
            switch filter {
            case .all:
                return person.photoCount >= 2 ? person : nil
            case .prominent:
                let days = Set(fs.compactMap { $0.date.map { Int(($0.timeIntervalSince1970 / 86_400).rounded(.down)) } })
                return person.photoCount >= 10 && (days.isEmpty || days.count >= 3) ? person : nil
            }
        }.sorted { $0.photoCount != $1.photoCount ? $0.photoCount > $1.photoCount : $0.id < $1.id }
    }

    /// A person by id, even one ``people(_:)`` does not list.
    public func person(_ id: Int) -> Person? {
        let fs = faces.filter { $0.person == id }
        return fs.isEmpty ? nil : Self.person(id, fs, names[id])
    }

    /// Who this face is: the person whose faces it matches best, if it clearly
    /// matches one. For a new photo, a camera frame, or the people in a meeting.
    public func person(for faceprint: Faceprint) -> Person? {
        best(faceprint, among: currentMeans(), photo: nil, rejected: []).flatMap { person($0.id) }
    }

    /// A face by id.
    public func face(_ id: String) -> FaceRecord? {
        index[id].map { faces[$0] }
    }

    /// Faces that may be this person and are not with them yet, most likely first:
    /// for "Is this also Noor?". Answer with ``confirm(_:is:)`` or ``reject(_:from:)``.
    public func suggestions(for person: Int, limit: Int = 20) -> [String] {
        let means = currentMeans().filter { $0.id == person }
        guard !means.isEmpty else { return [] }
        return faces.compactMap { f -> (String, Double)? in
            guard f.person != person, !f.confirmed, !f.rejected.contains(person),
                  let mean = means.first(where: { Embedder($0.faceprint) == Embedder(f.faceprint) }),
                  !mean.photos.contains(f.photo) else { return nil }
            let s = f.faceprint.similarity(to: mean.faceprint)
            return s >= Self.suggestCutoff ? (f.id, s) : nil
        }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// The faces whose person, confirmation or rejections changed since the last
    /// call, or since the library was created or loaded: the rows to write to your
    /// database.
    public mutating func takeChanges() -> [FaceRecord] {
        let changed = faces.filter { reported[$0.id] != Decision($0) }
        for f in changed { reported[f.id] = Decision(f) }
        return changed
    }

    /// Names a person, or clears the name with `nil`. A named person keeps the faces it has now.
    public mutating func name(_ person: Int, _ name: String?) {
        names[person] = name
        confirmAll(of: person)
    }

    /// "This is Noor": puts a face with a person, for good.
    public mutating func confirm(_ face: String, is person: Int) {
        guard let i = index[face] else { return }
        confirmAll(of: person)
        faces[i].person = person
        faces[i].confirmed = true
        faces[i].rejected.remove(person)
        nextPerson = max(nextPerson, person + 1)
        sums = nil
    }

    /// "This is not Noor": takes a face out of a person, or turns down a suggestion, for good. The face never joins
    /// that person again, and may join another.
    public mutating func reject(_ face: String, from person: Int) {
        guard let i = index[face] else { return }
        confirmAll(of: person)
        if faces[i].person == person {
            faces[i].person = nil
            faces[i].confirmed = false
        }
        faces[i].rejected.insert(person)
        sums = nil
    }

    /// "This is Ana", for someone the library has no person for: a new person with
    /// this one face and that name. If the face was with another person, the face
    /// never returns to that person. Faces that look like this face join the new
    /// person at the next regrouping. The answer is the new person's id, or `nil`
    /// if the library has no such face.
    @discardableResult
    public mutating func newPerson(from face: String, named name: String) -> Int? {
        guard let i = index[face] else { return nil }
        if let old = faces[i].person {
            confirmAll(of: old)
            faces[i].rejected.insert(old)
        }
        let person = nextPerson
        nextPerson += 1
        faces[i].person = person
        faces[i].confirmed = true
        names[person] = name
        sums = nil
        return person
    }

    /// "These are the same person": moves every face of `other` to `person`.
    public mutating func merge(_ other: Int, into person: Int) {
        guard other != person else { return }
        confirmAll(of: person)
        confirmAll(of: other)
        for i in faces.indices {
            if faces[i].person == other { faces[i].person = person }
            if faces[i].rejected.contains(other) { faces[i].rejected.insert(person) }
        }
        if names[person] == nil { names[person] = names[other] }
        names[other] = nil
        sums = nil
    }

    /// Regroups every face, keeping what the user said and every person's id.
    /// Adding faces regroups the library on its own as the library grows. Call
    /// `regroup()` after adding a large batch to see the full result at once.
    public mutating func regroup() {
        addedSinceGrouping = 0
        guard !faces.isEmpty else { return }
        var photoIndex: [String: Int32] = [:]
        let photo = faces.map { f -> Int32 in
            if let i = photoIndex[f.photo] { return i }
            let i = Int32(photoIndex.count)
            photoIndex[f.photo] = i
            return i
        }
        let clustered = faces.indices.filter { faces[$0].confidence >= Self.confidenceGate || faces[$0].confirmed }
        let inClusters = Set(clustered)
        // Faceprints of different embedders never compare, so each embedder's faces group on their own.
        var groups: [Int: [Int]] = [:]
        var base = 0
        // A person's photos across every embedder, so no embedder's pass puts a second face of one photo with them.
        var occupied: [Int: Set<Int32>] = [:]
        for i in clustered where faces[i].confirmed {
            if let p = faces[i].person { occupied[p, default: []].insert(photo[i]) }
        }
        let byEmbedder = Dictionary(grouping: clustered) { Embedder(faces[$0].faceprint) }
        for embedder in byEmbedder.keys.sorted() {
            let part = byEmbedder[embedder]!
            var byPerson: [Int: [Int]] = [:]
            var seeds: [Cluster.Seed] = []
            for (k, i) in part.enumerated() {
                if faces[i].confirmed, let p = faces[i].person { byPerson[p, default: []].append(k) } else {
                    seeds.append(Cluster.Seed(faces: [k], rejected: faces[i].rejected))
                }
            }
            for (p, members) in byPerson.sorted(by: { $0.key < $1.key }) {
                seeds.append(Cluster.Seed(faces: members, person: p,
                                          rejected: members.reduce(into: Set<Int>()) { $0.formUnion(faces[part[$1]].rejected) },
                                          occupied: occupied[p] ?? []))
            }
            let label = Cluster.group(part.map { faces[$0].faceprint.values }, photos: part.map { photo[$0] }, seeds: seeds)
            for (k, l) in label.enumerated() { groups[base + l, default: []].append(part[k]) }
            base += part.count
        }
        var owner: [Int: Int] = [:]
        for (l, members) in groups {
            if let i = members.first(where: { faces[$0].confirmed }) { owner[l] = faces[i].person }
        }
        groups = groups.filter { l, members in owner[l] != nil || members.count < 2 || !Self.isNoOne(members.map { faces[$0].faceprint }) }
        let taken = Set(owner.values)
        var overlaps: [(count: Int, group: Int, person: Int)] = []
        for (l, members) in groups where owner[l] == nil && Set(members.map { photo[$0] }).count >= 2 {
            var count: [Int: Int] = [:]
            for i in members { if let p = faces[i].person, !taken.contains(p) { count[p, default: 0] += 1 } }
            // A group keeps an old id only if none of its faces turned that person down.
            let rejected = members.reduce(into: Set<Int>()) { $0.formUnion(faces[$1].rejected) }
            for (p, c) in count where !rejected.contains(p) { overlaps.append((c, l, p)) }
        }
        var used = taken
        for o in overlaps.sorted(by: { ($0.count, -$0.person, -$0.group) > ($1.count, -$1.person, -$1.group) })
        where owner[o.group] == nil && !used.contains(o.person) {
            owner[o.group] = o.person
            used.insert(o.person)
        }
        for l in groups.keys.sorted() where owner[l] == nil && Set(groups[l]!.map { photo[$0] }).count >= 2 {
            owner[l] = nextPerson
            nextPerson += 1
        }
        for i in faces.indices where !faces[i].confirmed { faces[i].person = nil }
        for (l, members) in groups { if let p = owner[l] { for i in members { faces[i].person = p } } }
        sums = nil

        let people = means()
        var joined = Set<String>()
        for i in faces.indices where !inClusters.contains(i) {
            let f = faces[i]
            let free = people.filter { !joined.contains("\($0.id) \(f.photo)") }
            if let p = best(f.faceprint, among: free, photo: f.photo, rejected: f.rejected) {
                faces[i].person = p.id
                joined.insert("\(p.id) \(f.photo)")
            }
        }
        var members: [Int: [Int]] = [:]
        for i in faces.indices { if let p = faces[i].person { members[p, default: []].append(i) } }
        for (p, m) in members where names[p] == nil && !m.contains(where: { faces[$0].confirmed }) {
            let clear = m.filter { faces[$0].confidence >= Self.confidenceGate }.count
            if Double(clear) < Self.clearShare * Double(m.count) { for i in m { faces[i].person = nil } }
        }
        sums = nil
    }

    static let confidenceGate = 0.5
    static let clearShare = 0.5
    static let joinCutoff = 0.5
    static let suggestCutoff = 0.4
    static let hubCutoff = 0.56
    static let hub = Faceprint(values: [
        -0.06165, -0.07440, -0.05692, 0.05066, 0.15134, 0.00839, -0.01603, 0.09845, -0.08271, -0.12811, -0.06372,
        -0.03981, 0.04038, -0.08828, -0.05287, 0.05404, -0.00867, 0.05478, 0.03567, -0.00495, -0.07458, -0.07170,
        0.01256, 0.06393, -0.05655, 0.04668, 0.09129, 0.03182, 0.05088, -0.05108, -0.09256, -0.11842, 0.06883, 0.00302,
        -0.02189, 0.14394, -0.09096, -0.00631, 0.04980, 0.17850, -0.09012, 0.02179, 0.13274, -0.13737, 0.00064,
        -0.24820, 0.10677, 0.12472, -0.08103, 0.01388, -0.12668, -0.00805, -0.05626, 0.11206, 0.02519, -0.19253,
        0.12701, 0.01817, -0.08570, 0.20100, 0.05027, 0.00741, 0.04460, -0.08183, -0.02711, 0.00248, -0.16544, 0.09369,
        0.01907, 0.21508, 0.01715, -0.02375, -0.00389, -0.00446, -0.15049, -0.15596, -0.10868, 0.01494, -0.11951,
        0.08561, 0.07017, -0.06538, -0.07189, 0.10985, 0.16967, -0.02813, -0.09514, 0.01560, -0.08683, -0.15779,
        0.02541, -0.02060, 0.02047, 0.14184, 0.01642, 0.01602, -0.13420, 0.00456, -0.05320, 0.00350, 0.00317, -0.03274,
        0.03873, -0.04085, 0.01580, -0.10201, -0.00950, 0.04042, 0.13167, 0.04226, 0.08594, 0.07648, -0.11371, -0.10380,
        -0.02071, 0.07034, -0.05818, -0.19413, 0.09524, 0.07915, 0.08337, 0.06363, -0.10645, -0.00665, -0.03892,
        0.12679, 0.10493, 0.02859,
    ])

    static func isNoOne(_ faceprints: [Faceprint]) -> Bool {
        guard let mean = Faceprint(averaging: faceprints), mean.model == hub.model else { return false }
        return mean.similarity(to: hub) >= hubCutoff
    }

    struct Decision: Hashable, Sendable {
        let person: Int?
        let confirmed: Bool
        let rejected: Set<Int>

        init(_ f: FaceRecord) {
            person = f.person
            confirmed = f.confirmed
            rejected = f.rejected
        }
    }

    struct Mean {
        let id: Int
        let faceprint: Faceprint
        let photos: Set<String>
    }

    /// The embedder a faceprint comes from: its model and its length. Faces of one embedder group, average and match
    /// only with each other.
    struct Embedder: Hashable, Comparable {
        let model: String
        let count: Int

        init(_ faceprint: Faceprint) {
            model = faceprint.model
            count = faceprint.values.count
        }

        static func < (a: Embedder, b: Embedder) -> Bool { (a.model, a.count) < (b.model, b.count) }
    }

    /// One person's faces of one embedder.
    struct SumKey: Hashable {
        let person: Int
        let embedder: Embedder
    }

    private static func person(_ id: Int, _ fs: [FaceRecord], _ name: String?) -> Person {
        Person(id: id, name: name,
               faces: fs.sorted { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.id < $1.id }.map(\.id),
               photoCount: Set(fs.map(\.photo)).count)
    }

    private func record(_ face: DetectedFace, id: String, photo: String, date: Date?) -> FaceRecord {
        FaceRecord(id: id, photo: photo, date: date, box: face.box, confidence: face.confidence, faceprint: face.faceprint)
    }

    private mutating func settle() {
        index = [:]
        photoFaces = [:]
        for (i, f) in faces.enumerated() {
            index[f.id] = i
            photoFaces[f.photo, default: 0] += 1
        }
        let ids = faces.flatMap { [$0.person].compactMap { $0 } + $0.rejected } + names.keys
        nextPerson = max(nextPerson, (ids.max() ?? 0) + 1)
        // Only faces added since the last regrouping count toward the next: not the ones a load brings, nor the
        // strangers a regrouping left on their own.
        addedSinceGrouping = min(addedSinceGrouping, faces.count)
        reported = Dictionary(uniqueKeysWithValues: faces.map { ($0.id, Decision($0)) })
        sums = nil
    }

    private mutating func insert(_ new: [FaceRecord]) {
        var added: [Int] = []
        for var f in new {
            if let i = index[f.id] {
                f.person = faces[i].person
                f.confirmed = faces[i].confirmed
                f.rejected = faces[i].rejected
                // A new faceprint, box, date or confidence is a change to save, like a new decision.
                if f != faces[i] { reported[f.id] = nil }
                photoFaces[faces[i].photo, default: 1] -= 1
                photoFaces[f.photo, default: 0] += 1
                faces[i] = f
                sums = nil
            } else {
                index[f.id] = faces.count
                photoFaces[f.photo, default: 0] += 1
                added.append(faces.count)
                faces.append(f)
            }
        }
        addedSinceGrouping += added.count
        if addedSinceGrouping >= max(16, faces.count / 4) {
            regroup()
            return
        }
        let people = means()
        var taken = Set<String>()
        for i in added where faces[i].confidence >= Self.confidenceGate {
            let f = faces[i]
            let free = people.filter { !taken.contains("\($0.id) \(f.photo)") }
            if let p = best(f.faceprint, among: free, photo: f.photo, rejected: f.rejected) {
                faces[i].person = p.id
                taken.insert("\(p.id) \(f.photo)")
                let key = SumKey(person: p.id, embedder: Embedder(f.faceprint))
                sums?[key]?.photos.insert(f.photo)
                for k in f.faceprint.values.indices { sums?[key]?.sum[k] += f.faceprint.values[k] }
            }
        }
    }

    private mutating func means() -> [Mean] {
        if sums == nil {
            var s: [SumKey: (sum: [Float], photos: Set<String>)] = [:]
            for f in faces {
                guard let p = f.person else { continue }
                let key = SumKey(person: p, embedder: Embedder(f.faceprint)), v = f.faceprint.values
                if s[key] == nil { s[key] = ([Float](repeating: 0, count: v.count), []) }
                for k in v.indices { s[key]!.sum[k] += v[k] }
                s[key]!.photos.insert(f.photo)
            }
            sums = s
        }
        return Self.means(sums!)
    }

    private func currentMeans() -> [Mean] {
        if let sums { return Self.means(sums) }
        var copy = self
        return copy.means()
    }

    /// One mean per person and embedder. A person's photos are every photo of theirs, whatever embedder the faces in
    /// them come from: two faces of one photo are never one person.
    private static func means(_ sums: [SumKey: (sum: [Float], photos: Set<String>)]) -> [Mean] {
        var photos: [Int: Set<String>] = [:]
        for (key, value) in sums { photos[key.person, default: []].formUnion(value.photos) }
        return sums.keys.sorted { ($0.person, $0.embedder) < ($1.person, $1.embedder) }.map { key in
            Mean(id: key.person, faceprint: Faceprint(values: sums[key]!.sum, model: key.embedder.model),
                 photos: photos[key.person]!)
        }
    }

    private func best(_ f: Faceprint, among people: [Mean], photo: String?, rejected: Set<Int>) -> Mean? {
        var top: (Mean, Double)?
        for m in people where Embedder(m.faceprint) == Embedder(f) && !rejected.contains(m.id) && !(photo.map(m.photos.contains) ?? false) {
            let s = f.similarity(to: m.faceprint)
            if s >= Self.joinCutoff && s > (top?.1 ?? -2) { top = (m, s) }
        }
        return top?.0
    }

    private mutating func confirmAll(of person: Int) {
        for i in faces.indices where faces[i].person == person { faces[i].confirmed = true }
    }

    private mutating func removeFaces(where gone: (FaceRecord) -> Bool) {
        let ids = Set(faces.filter(gone).map(\.id))
        guard !ids.isEmpty else { return }
        faces.removeAll { ids.contains($0.id) }
        for id in ids { reported[id] = nil }
        let kept = reported
        settle()
        reported = kept
    }
}
