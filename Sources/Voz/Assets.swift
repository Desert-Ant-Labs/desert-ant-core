import Foundation

/// The model's host-side half: geometry, vocabulary, and the embedding table.
///
/// The three compiled programs are the engine's (`Engine+CoreML.swift`,
/// `Engine+Wasm.swift`); what stays here is everything the pipeline reads
/// itself, which is portable.
struct Assets {
    let configuration: Configuration
    let vocabulary: [String]
    /// Row-major `[vocab + 1, predHidden]` in the engine's element type, so a
    /// decode step copies a row without converting. The embedding stays outside
    /// the graph: a gather over an 8193 x 640 table has no Neural Engine kernel
    /// and is a table read the host does for free.
    private let embedding: [Element]

    /// Build from the sidecars, whatever fetched them.
    ///
    /// `embeddingBytes` is the raw `embedding.f16` file. On Apple that is
    /// already the layout a decode reads and it is used as is; off Apple the
    /// buffers are float32, so the table is widened once here rather than per
    /// row per step.
    init(meta: Data, vocab: Data, embeddingBytes: Data) throws {
        let decoder = JSONDecoder()
        configuration = try decoder.decode(Configuration.self, from: meta)
        try configuration.validate()
        vocabulary = try decoder.decode([String].self, from: vocab)
        guard vocabulary.count >= configuration.vocabSize else {
            throw VozError.invalidModel("vocabulary is smaller than the model's vocab size")
        }

        let expected = (configuration.vocabSize + 1) * configuration.predHidden
        guard embeddingBytes.count == expected * 2 else {
            throw VozError.invalidModel(
                "embedding.f16 has \(embeddingBytes.count) bytes, expected \(expected * 2)")
        }
        #if canImport(CoreML)
        embedding = embeddingBytes.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Element.self).prefix(expected))
        }
        #else
        // float16 is what the file holds and float32 is what the wasm boundary
        // carries, so the widening happens once, here.
        embedding = embeddingBytes.withUnsafeBytes { raw -> [Element] in
            let halves = raw.bindMemory(to: UInt16.self)
            return (0..<expected).map { Element(Float16(bitPattern: halves[$0])) }
        }
        #endif
    }

    /// The embedding table, for the decode step's per-lane row copy.
    func withEmbedding<T>(_ body: (UnsafeBufferPointer<Element>) throws -> T) rethrows -> T {
        try embedding.withUnsafeBufferPointer { try body($0) }
    }
}
