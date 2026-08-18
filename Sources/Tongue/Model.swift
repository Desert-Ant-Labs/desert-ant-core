import Foundation

// The head. There is no inference runtime here and none is needed: a detection
// is an int8 embedding gather, a sum over the n-grams present, one small matmul
// and a masked softmax — a few thousand multiply-adds.
//
// Byte-oriented on purpose, matching emo: the core initializer takes `[UInt8]` and
// a JSON string rather than a URL, so callers can supply a downloaded or embedded
// model. File reading lives in TongueLoading.swift.
//
// Byte layout of tongue_int8.bin, as written by scripts/build_release.py:
//
//   [0]                   int8   embedding, numBuckets * dim, row-major
//   [numBuckets*dim]      fp32   linear weight, labels * dim, row-major
//   [+ labels*dim*4]      fp32   linear bias, labels
//
// fp32 fields are little-endian, which every platform this ships on is.

struct Metadata: Decodable, Sendable {
    let labels: [String]
    let numBuckets: Int
    let dimension: Int
    let ngramOrders: [Int]
    let embeddingScale: Float
    /// Labels reachable when the router could not narrow the script. Absent in
    /// older metadata, in which case every label competes.
    let latinLabels: [String]

    private enum CodingKeys: String, CodingKey {
        case labels
        case numBuckets = "num_buckets"
        case dimension = "dim"
        case ngramOrders = "ngram_orders"
        case embeddingScale = "embed_scale"
        case latinLabels = "latin_labels"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        labels = try container.decode([String].self, forKey: .labels)
        numBuckets = try container.decode(Int.self, forKey: .numBuckets)
        dimension = try container.decode(Int.self, forKey: .dimension)
        ngramOrders = try container.decode([Int].self, forKey: .ngramOrders)
        embeddingScale = try container.decode(Float.self, forKey: .embeddingScale)
        latinLabels = try container.decodeIfPresent([String].self, forKey: .latinLabels) ?? labels
    }

    init(json: String) throws {
        do {
            self = try JSONDecoder().decode(Metadata.self, from: Data(json.utf8))
        } catch {
            throw TongueError.malformedMetadata(String(describing: error))
        }
    }
}

struct Weights: Sendable {
    private let embedding: [Int8]
    private let linearWeight: [Float]
    private let linearBias: [Float]
    private let labels: [String]
    private let numBuckets: Int
    private let dimension: Int
    private let ngramOrders: [Int]
    private let scale: Float

    init(bytes: [UInt8], metadata: Metadata) throws {
        let labelCount = metadata.labels.count
        let embeddingCount = metadata.numBuckets * metadata.dimension
        let weightCount = labelCount * metadata.dimension
        let expected = embeddingCount + (weightCount + labelCount) * 4
        guard bytes.count == expected else {
            throw TongueError.weightsSizeMismatch(expected: expected, actual: bytes.count)
        }

        embedding = bytes.prefix(embeddingCount).map { Int8(bitPattern: $0) }
        var offset = embeddingCount
        linearWeight = Weights.floats(bytes, at: &offset, count: weightCount)
        linearBias = Weights.floats(bytes, at: &offset, count: labelCount)

        labels = metadata.labels
        numBuckets = metadata.numBuckets
        dimension = metadata.dimension
        ngramOrders = metadata.ngramOrders
        scale = metadata.embeddingScale
    }

    /// Decode little-endian fp32 without assuming alignment: the offsets into the
    /// file are not guaranteed to be 4-byte aligned, so this shifts bytes rather
    /// than reinterpreting memory.
    private static func floats(_ bytes: [UInt8], at offset: inout Int, count: Int) -> [Float] {
        var out = [Float]()
        out.reserveCapacity(count)
        for index in 0..<count {
            let base = offset + index * 4
            let bits = UInt32(bytes[base])
                | UInt32(bytes[base + 1]) << 8
                | UInt32(bytes[base + 2]) << 16
                | UInt32(bytes[base + 3]) << 24
            out.append(Float(bitPattern: bits))
        }
        offset += count * 4
        return out
    }

    /// Top-`k` languages for already-normalized text, decoded over `allowed` only.
    ///
    /// The mask is how the router composes with the head: Cyrillic input competes
    /// among the Cyrillic labels, not all 59. Excluded labels get probability zero
    /// and the remaining mass renormalizes over the candidates.
    func rank(_ text: String, restrictedTo allowed: Set<String>, topK: Int) -> [Prediction] {
        var pooled = [Float](repeating: 0, count: dimension)
        // Ascending bucket order, not the hash table's. Float addition is not
        // associative, so the accumulation order is part of the answer: Swift
        // randomises Dictionary iteration per process, which made `detect` return
        // different probabilities on every launch and flipped `language`,
        // `reliability` and `isTooCloseToCall` on inputs near a threshold. Kotlin
        // and JavaScript sort the same way, so all three now pool identically.
        for (bucket, count) in Hashing.buckets(text, numBuckets: numBuckets, orders: ngramOrders)
            .sorted(by: { $0.key < $1.key }) {
            let base = bucket * dimension
            let weight = Float(count) * scale
            for index in 0..<dimension {
                pooled[index] += Float(embedding[base + index]) * weight
            }
        }

        var logits: [(String, Float)] = []
        logits.reserveCapacity(allowed.count)
        for (labelIndex, label) in labels.enumerated() where allowed.contains(label) {
            var sum = linearBias[labelIndex]
            let base = labelIndex * dimension
            for index in 0..<dimension {
                sum += linearWeight[base + index] * pooled[index]
            }
            logits.append((label, sum))
        }
        guard !logits.isEmpty else { return [] }

        let maximum = logits.map(\.1).max() ?? 0
        let exponentiated = logits.map { ($0.0, exp(Double($0.1 - maximum))) }
        let total = exponentiated.reduce(0) { $0 + $1.1 }
        return exponentiated
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map { Prediction(language: $0.0, probability: total > 0 ? $0.1 / total : 0) }
    }
}
