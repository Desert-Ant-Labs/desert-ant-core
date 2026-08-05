import DesertAnt

/// The model sidecar (`emo_meta.json`): the emoji label order the classifier
/// emits and the tokenizer/featurizer constants the exports were built with.
/// Shipped next to every artifact so the runtime hashes, tokenizes, and pads
/// exactly the way the model was trained and exported, on every platform.
struct EmoMeta: Sendable, Decodable {
    /// One emoji per classifier output index.
    let labels: [String]
    /// Number of FNV hashes per n-gram feature.
    let nHashes: Int
    /// n-gram hash-bucket table size.
    let nBuckets: Int
    /// Importance-table size.
    let nImportance: Int
    /// The padding row appended to the semantic table (index == real table size).
    let semPadIndex: Int
    /// Fixed n-gram feature window the exports use (features beyond it are dropped).
    let fmax: Int
    /// Fixed semantic-token window the exports use (tokens beyond it are dropped).
    let smax: Int

    enum CodingKeys: String, CodingKey {
        case labels
        case nHashes = "n_hashes"
        case nBuckets = "n_buckets"
        case nImportance = "n_importance"
        case semPadIndex = "sem_pad_index"
        case fmax
        case smax
    }

    /// Parse the JSON sidecar with the platform's native decoder (Codable).
    init(json: String) throws {
        self = try JSONDecoder().decode(EmoMeta.self, from: json)
    }
}
