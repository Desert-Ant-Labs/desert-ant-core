/// Working across photos: near-duplicates, the best of a set, similar photos.
/// Pure functions over analyses (stored ones too); no model needed.
extension Eye {
    /// Groups of near-duplicates, as indices into `analyses`, each group at least
    /// two photos, best first (see ``best(of:)``). Photos without an embedding
    /// are left out.
    ///
    /// - Parameter dates: each photo's capture time in seconds (any epoch), or
    ///   `nil` for none. With dates, only photos taken within the model's
    ///   window of each other (seconds, shorter when people are in them) are
    ///   duplicates; without, any two similar enough photos are.
    public static func duplicates(in analyses: [Analysis], dates: [Double?]? = nil) -> [[Int]] {
        let n = analyses.count
        var parent = Array(0..<n)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        let order: [Int]
        if let dates {
            order = (0..<n).filter { $0 < dates.count && dates[$0] != nil }.sorted { dates[$0]! < dates[$1]! }
        } else {
            order = Array(0..<n)
        }
        for (k, i) in order.enumerated() {
            guard let rule = analyses[i].duplicates, analyses[i].embedding != nil else { continue }
            for j in order[(k + 1)...] {
                if let dates, let ti = dates[i], let tj = dates[j] {
                    let people = analyses[i].has(.people) || analyses[j].has(.people)
                    if tj - ti > max(rule.windowSeconds, rule.windowSecondsPeople) { break }
                    if tj - ti > (people ? rule.windowSecondsPeople : rule.windowSeconds) { continue }
                }
                if let s = analyses[i].similarity(to: analyses[j]), s >= rule.similarity {
                    parent[root(j)] = root(i)
                }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in 0..<n where analyses[i].embedding != nil { groups[root(i), default: []].append(i) }
        return groups.values.filter { $0.count > 1 }
            .map { g in g.sorted { better(analyses[$0], than: analyses[$1]) } }
            .sorted { $0[0] < $1[0] }
    }

    /// The index of the photo to keep from a set (a burst, a group of
    /// near-duplicates): no one's eyes closed, then the best faces, then the
    /// keeper score. `nil` for an empty set.
    public static func best(of analyses: [Analysis]) -> Int? {
        analyses.indices.max { better(analyses[$1], than: analyses[$0]) }
    }

    /// Photos ranked by similarity to `photo`, most similar first, as
    /// (index into `analyses`, cosine similarity).
    public static func similar(to photo: Analysis, in analyses: [Analysis], limit: Int = 20) -> [(index: Int, similarity: Double)] {
        Array(analyses.indices.compactMap { i in photo.similarity(to: analyses[i]).map { (index: i, similarity: $0) } }
            .sorted { $0.similarity > $1.similarity }.prefix(max(0, limit)))
    }

    static func better(_ a: Analysis, than b: Analysis) -> Bool {
        let x = rank(a), y = rank(b)
        return x != y && !x.lexicographicallyPrecedes(y)
    }

    /// No closed eyes, then face quality to a tenth, then keeper.
    static func rank(_ a: Analysis) -> [Double] {
        let faces = (a.faces ?? []).filter { $0.detectionConfidence >= 0.5 }
        let quality = faces.isEmpty ? 0.5 : faces.reduce(0) { $0 + $1.quality * $1.box.width * $1.box.height }
            / max(faces.reduce(0) { $0 + $1.box.width * $1.box.height }, 1e-9)
        return [a.has(.eyesClosed) ? 0 : 1, (quality * 10).rounded() / 10, a.scores?.keeper ?? 0]
    }
}
