import DesertAnt
import RealModule

/// The full hybrid detector: tokenization, windowing, BIOES decoding, and the
/// deterministic-owner merge. Inference goes through the shared
/// `InferenceSession` (Core ML | LiteRT | JS host, chosen by
/// DesertAnt); this file only knows redact's fixed-256 tensor window.
final class Model: @unchecked Sendable {
    private let session: any InferenceSession
    private let tokenizer: Tokenizer
    private let id2label: [Int: String]

    private static let seq = 256
    private static let maxContent = seq - 2      // room for <s> … </s>
    private static let lowScore = 0.3
    // BERT position ids: 0..<seq, matching both exports.
    private static let positionIDs: [Int32] = (0..<seq).map(Int32.init)
    private static let typeIDs = [Int32](repeating: 0, count: seq)

    init(assets: ModelAssets) throws {
        guard let tok = Tokenizer(bytes: assets.tokenizer) else { throw RedactError.resourceMissing }
        tokenizer = tok
        id2label = try Model.parseLabels(assets.labelsJSON)
        session = assets.session
    }

    /// `labels.json` is `{"id2label": {"0": "O", ...}}`; decode it with the
    /// platform's native JSON (NativeJSON, Codable) into `id -> label`.
    private struct Labels: Decodable { let id2label: [String: String] }
    private static func parseLabels(_ json: String) throws -> [Int: String] {
        let labels = try JSONDecoder().decode(Labels.self, from: json)
        var out: [Int: String] = [:]
        for (key, label) in labels.id2label {
            if let id = Int(key) { out[id] = label }
        }
        guard !out.isEmpty else { throw RedactError.resourceMissing }
        return out
    }

    // MARK: public entry - full hybrid detection
    func detect(_ text: String, minScore: Double) async throws -> [Span] {
        let threshold = minScore.isFinite ? min(1, max(0, minScore)) : 0.6
        let det = Deterministic.detect(text, enabled: Deterministic.owned)
        let masked = Pipeline.maskText(text, det)
        let ml = try await mlSpans(Pipeline.modelInput(for: masked), minScore: threshold)
        let corr = Deterministic.detect(text, enabled: ["PHONE"]).filter { !Deterministic.owned.contains($0.label) }
        return Pipeline.cleanSpans(text, Pipeline.relabelByContext(text, Pipeline.resolve(det + corr, ml)))
    }

    // MARK: neural spans (windowed)
    private func mlSpans(_ text: String, minScore: Double) async throws -> [Span] {
        let t = UTF16Text(text)
        let tokens = tokenizer.tokenize(text)
        let offsets = reconstructOffsets(t, tokens)
        let low = min(Model.lowScore, minScore)

        var scored: [(Span, Double)] = []
        var i = 0
        while i < tokens.count {
            let chunk = Array(tokens[i..<min(i + Model.maxContent, tokens.count)])
            let chunkOffsets = Array(offsets[i..<i + chunk.count])
            let (tags, tagOffsets, probs) = try await runWindow(chunk, chunkOffsets)
            // score = max token prob overlapping each BIOES span (within this window)
            let usableTags = zip(tags, probs).map { $0.1 >= low ? $0.0 : "O" }
            for span in Pipeline.bioesToSpans(usableTags, tagOffsets) {
                var mx = 0.0
                for (k, (a, b)) in tagOffsets.enumerated() where b > a && max(a, span.start) < min(b, span.end) {
                    mx = max(mx, probs[k])
                }
                scored.append((span, mx))
            }
            i += chunk.count
        }

        var kept = Pipeline.hysteresis(t, scored, minScore)
        kept = Pipeline.mergePriority(kept)
        kept = Pipeline.attachBuildingNumbers(t, Pipeline.extendParticleNames(t, Pipeline.bridgeNameGaps(t, Pipeline.snapSpans(t, kept))))
        kept = Pipeline.redactSecondaryAddress(t, Pipeline.attachStateCodes(t, Pipeline.redactUsStreet(t, kept)))
        return Pipeline.mergePriority(kept)
    }

    /// Run one window (<= 256 incl. specials); returns (tags, offsets, probs).
    private func runWindow(_ chunk: [Tokenizer.Token], _ chunkOffsets: [(Int, Int)]) async throws
        -> ([String], [(Int, Int)], [Double]) {
        let ids = [tokenizer.bosID] + chunk.map(\.id) + [tokenizer.eosID]
        let realLen = ids.count
        var offs: [(Int, Int)] = [(0, 0)] + chunkOffsets + [(0, 0)]

        let (logits, numLabels) = try await logits(ids: ids)
        guard numLabels > 0, logits.count == realLen * numLabels else {
            throw RedactError.predictionFailed
        }

        var tags = [String](repeating: "O", count: realLen)
        var probs = [Double](repeating: 0, count: realLen)
        for k in 0..<realLen {
            var mx = -Double.greatestFiniteMagnitude, top = 0
            for c in 0..<numLabels {
                let v = Double(logits[k * numLabels + c])
                if v > mx { mx = v; top = c }
            }
            var sum = 0.0
            for c in 0..<numLabels { sum += Double.exp(Double(logits[k * numLabels + c]) - mx) }
            tags[k] = id2label[top] ?? "O"
            probs[k] = Double.exp(Double(logits[k * numLabels + top]) - mx) / sum
        }
        if offs.count > realLen { offs = Array(offs.prefix(realLen)) }
        return (tags, offs, probs)
    }

    /// Map each content sub-word to its char range in the source string by
    /// scanning its surface (minus the `▁` metaspace) forward from a cursor.
    private func reconstructOffsets(_ t: UTF16Text, _ tokens: [Tokenizer.Token]) -> [(Int, Int)] {
        var cursor = 0
        var out: [(Int, Int)] = []
        out.reserveCapacity(tokens.count)
        for tok in tokens {
            var scalars = tok.scalars
            if scalars.first == "\u{2581}" { scalars.removeFirst() }
            if scalars.isEmpty { out.append((cursor, cursor)); continue }
            let core = String(String.UnicodeScalarView(scalars))
            if let r = t.find(core, from: cursor) {
                out.append((r.start, r.end))
                cursor = r.end
            } else {
                out.append((cursor, cursor))
            }
        }
        return out
    }

    // MARK: inference (redact's fixed-256 window over the shared session)

    /// Run the token classifier over one window (<= 256 ids incl. specials):
    /// both the Core ML and the LiteRT exports take a fixed 256, int32 window
    /// with baked position ids, returning row-major logits (`ids.count *
    /// numLabels` values, the first `realLen` rows real). The LiteRT `.tflite`
    /// declares only `input_ids` and `attention_mask` (positions/type ids are
    /// baked into the graph) and the session ignores extra inputs, so the same
    /// tensor dict serves both.
    private func logits(ids: [Int]) async throws -> (values: [Float], numLabels: Int) {
        let realLen = ids.count
        guard realLen > 0, realLen <= Self.seq else { throw RedactError.predictionFailed }
        var padded = [Int32](repeating: 1, count: Self.seq)   // <pad>
        var mask = [Int32](repeating: 0, count: Self.seq)
        for k in 0..<realLen {
            padded[k] = Int32(ids[k])
            mask[k] = 1
        }
        let logits = try await session.run(
            inputs: [
                "input_ids": Tensor(int32: padded, shape: [1, Self.seq]),
                "attention_mask": Tensor(int32: mask, shape: [1, Self.seq]),
                "position_ids": Tensor(int32: Self.positionIDs, shape: [1, Self.seq]),
                "token_type_ids": Tensor(int32: Self.typeIDs, shape: [1, Self.seq]),
            ],
            outputs: ["logits"])[0]
        guard logits.shape.count == 3, let all = logits.float32Values else {
            throw RedactError.predictionFailed
        }
        let numLabels = logits.shape[2]
        guard numLabels > 0, all.count >= realLen * numLabels else { throw RedactError.predictionFailed }
        // The window is padded to 256 rows; only the first realLen are real.
        return (Array(all[0..<(realLen * numLabels)]), numLabels)
    }
}
