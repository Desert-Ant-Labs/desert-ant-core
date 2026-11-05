import DesertAnt

/// Tokenization, the lookup of each window's rows, the windows of a long text, the graph, and the heads'
/// probabilities.
final class Model: @unchecked Sendable {
    private let session: any InferenceSession
    private let tokenizer: Tokenizer
    private let table: Table
    let meta: Meta
    /// The heads in the graph's output order.
    let heads: [Label]
    /// The meta's threshold per head, a disabled head's set out of reach.
    let defaultThresholds: [Label: Double]

    private let embeddings: String
    private let attentionMask: String
    private let output: String
    /// The window the graph reads, and the pieces it holds beside bos and eos.
    private let window: Int
    private let content: Int
    /// A long text is read in windows that overlap by this many pieces, so a sentence cut by one window is whole
    /// in the next.
    private static let overlap = 26

    init(assets: ModelAssets) throws {
        meta = try Meta.parse(assets.metaJSON)
        guard let tokenizer = Tokenizer(bytes: assets.tokenizer) else { throw ToxicError.resourceMissing }
        guard tokenizer.maxLength == meta.tokenizer.maxLength, tokenizer.bosID == meta.tokenizer.bos,
              tokenizer.eosID == meta.tokenizer.eos, tokenizer.padID == meta.tokenizer.pad else {
            throw ToxicError.invalidModel("the tokenizer and the meta disagree on the window or the special ids")
        }
        self.tokenizer = tokenizer
        guard let table = Table(bytes: assets.table) else { throw ToxicError.resourceMissing }
        guard let info = meta.table, table.rows == info.rows, table.cols == info.cols else {
            throw ToxicError.invalidModel("the table and the meta disagree on its shape")
        }
        self.table = table
        heads = try meta.output.heads.map { name in
            guard let label = Label(rawValue: name) else { throw ToxicError.invalidModel("unknown head \(name)") }
            return label
        }
        guard Set(heads) == Set(Label.allCases) else { throw ToxicError.invalidModel("the graph does not carry every head") }
        var thresholds: [Label: Double] = [:]
        for label in heads {
            thresholds[label] = meta.disabledHeads.contains(label.rawValue) ? .infinity : (meta.thresholds[label.rawValue] ?? 0.5)
        }
        defaultThresholds = thresholds
        embeddings = meta.inputs[0].name
        attentionMask = meta.inputs[1].name
        output = meta.output.name
        window = meta.tokenizer.maxLength
        content = window - 2
        session = assets.session
    }

    /// Every head's probability for `text`: one window, or the highest over the windows of a long text.
    func scores(for text: String) async throws -> [Label: Double] {
        let pieces = tokenizer.pieces(of: text)
        var best = [Double](repeating: 0, count: heads.count)
        var start = 0
        while true {
            let end = min(start + content, pieces.count)
            let probabilities = try await self.probabilities(ofWindow: [tokenizer.bosID] + pieces[start..<end] + [tokenizer.eosID])
            for (k, p) in probabilities.enumerated() { best[k] = max(best[k], p) }
            if end == pieces.count { break }
            start += content - Self.overlap
        }
        return Dictionary(uniqueKeysWithValues: zip(heads, best))
    }

    /// The graph on one window: `ids` is bos, the pieces and eos, at most the window long; padded here with the
    /// pad id, every id's row looked up from the table and fed as the graph's embeddings. The tensors go in as
    /// float32; a session whose graph takes float16 converts them.
    func probabilities(ofWindow ids: [Int32]) async throws -> [Double] {
        guard ids.count >= 2, ids.count <= window else { throw ToxicError.predictionFailed("a window of \(ids.count) ids") }
        var padded = [Int32](repeating: tokenizer.padID, count: window)
        var mask = [Float](repeating: 0, count: window)
        for (k, id) in ids.enumerated() {
            padded[k] = id
            mask[k] = 1
        }
        let out = try await session.run(
            inputs: [embeddings: Tensor(float32: table.rows(of: padded), shape: [1, window, table.cols]),
                     attentionMask: Tensor(float32: mask, shape: [1, window])],
            outputs: [output])
        guard let values = out.first?.float32Values, values.count == heads.count, values.allSatisfy(\.isFinite) else {
            throw ToxicError.predictionFailed("the graph returned no probabilities")
        }
        return values.map { min(1, max(0, Double($0))) }
    }

    /// The model's one window for `text`, as the training transform encodes it; for the tests.
    func encode(_ text: String) -> [Int32] { tokenizer.encode(text) }

    /// One row of the table; for the tests.
    func row(_ id: Int32) -> [Float] { table.rows(of: [id]) }
}
