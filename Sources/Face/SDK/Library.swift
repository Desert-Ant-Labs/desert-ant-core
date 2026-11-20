/// A face that matched in ``Face/matches(for:in:level:)``.
public struct Match: Sendable, Hashable {
    /// The face's position in the faceprints you searched.
    public let index: Int
    /// Cosine similarity to the reference.
    public let similarity: Double
}

public extension Face {
    /// The faces of one person among many: every faceprint that matches
    /// `reference` at `level`, most similar first. For "every photo of Noor" from
    /// a selfie or a few tagged photos (``Faceprint/init(averaging:)``).
    static func matches(for reference: Faceprint, in faceprints: [Faceprint], level: Faceprint.Level = .recommended) -> [Match] {
        faceprints.enumerated().compactMap { i, f in
            guard f.isComparable(to: reference) else { return nil }
            let s = reference.similarity(to: f)
            return s >= level.cutoff ? Match(index: i, similarity: s) : nil
        }.sorted { $0.similarity > $1.similarity }
    }
}
