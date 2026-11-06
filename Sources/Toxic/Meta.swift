import Foundation

/// `toxic_meta.json`, schema 4: what the SDK needs to run one published variant.
struct Meta: Decodable, Sendable {
    struct Graph: Decodable, Sendable {
        let file: String
        /// `cpu_and_ne` for the Core ML program, `cpu` for LiteRT.
        let computeUnits: String
        /// The LiteRT signature; absent for Core ML.
        let signature: String?
    }

    struct Port: Decodable, Sendable {
        let name: String
        let dtype: String
        let shape: [Int]
    }

    struct Output: Decodable, Sendable {
        let name: String
        let dtype: String
        let shape: [Int]
        /// The heads in the output's order.
        let heads: [String]
    }

    struct TableInfo: Decodable, Sendable {
        let file: String
        let rows: Int
        let cols: Int
        let group: Int
        let levels: Int
    }

    struct TokenizerInfo: Decodable, Sendable {
        let file: String
        /// The window: bos, the pieces, eos, then pad.
        let maxLength: Int
        let bos: Int32
        let eos: Int32
        let pad: Int32
        let unk: Int32
    }

    let schema: Int
    let version: String
    let graph: Graph
    /// `embeddings` then `attention_mask`, both float.
    let inputs: [Port]
    /// The shared table the embeddings come from.
    let table: TableInfo?
    let output: Output
    let tokenizer: TokenizerInfo
    /// The default decision threshold per head, chosen on validation text.
    let thresholds: [String: Double]
    /// Heads pinned to an unreachable threshold on every platform.
    let disabledHeads: [String]

    static func parse(_ json: String) throws -> Meta {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let meta = try decoder.decode(Meta.self, from: Data(json.utf8))
        guard meta.schema == 4 else { throw ToxicError.invalidModel("meta schema \(meta.schema), this SDK reads schema 4") }
        guard meta.inputs.count == 2, meta.output.heads.count == meta.output.shape.last else {
            throw ToxicError.invalidModel("the meta's inputs or heads do not match its graph")
        }
        guard let table = meta.table, meta.inputs[0].shape == [1, meta.tokenizer.maxLength, table.cols] else {
            throw ToxicError.invalidModel("the graph takes embeddings from the shared table; the meta names none that fits")
        }
        return meta
    }
}
