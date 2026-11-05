import Foundation
import Testing
import DesertAnt
import TestSupport
@testable import Toxic
@_spi(ToxicBindings) import Toxic

/// The goldens come from ml-toxic's shipping exports: the golden texts, their ids as the training transform
/// encodes them, the torch float32 reference, and each published artifact's own probabilities. The tokenizer
/// oracle is the same transform on edge cases (whitespace runs, added tokens, scripts, emoji, long texts).
struct ToxicTests {
    // MARK: decisions, no model

    @Test func flagsFollowThresholds() {
        var scores = Dictionary(uniqueKeysWithValues: Label.allCases.map { ($0, 0.1) })
        scores[.hateful] = 0.7
        scores[.race] = 0.6
        scores[.gender] = 0.5
        let thresholds = Dictionary(uniqueKeysWithValues: Label.allCases.map { ($0, 0.5) })
        let a = Analysis(scores: scores, thresholds: thresholds)
        #expect(a.isToxic && a.content == [.hateful] && a.targets == [.race, .gender])
        #expect(a.score(.abusive) == 0.1 && a.flagged == [.hateful, .race, .gender])
        let strict = Analysis(scores: scores, thresholds: thresholds.merging([.hateful: 0.9, .race: 0.9]) { $1 })
        #expect(!strict.isToxic && strict.targets == [.gender])
        let disabled = Analysis(scores: scores, thresholds: thresholds.merging([.hateful: .infinity]) { $1 })
        #expect(!disabled.flagged.contains(.hateful))
    }

    @Test func optionsDropNonFiniteThresholds() {
        let options = Options(thresholds: [.hateful: 0.3, .threat: .nan])
        #expect(options.thresholds == [.hateful: 0.3])
    }

    @Test func labelsSplitIntoContentAndTargets() {
        #expect(Label.content.count + Label.targets.count == Label.allCases.count)
        #expect(Label.content.allSatisfy { !$0.isTarget } && Label.targets.allSatisfy(\.isTarget))
        #expect(Label.allCases.map(\.rawValue) == ["HATEFUL", "ABUSIVE", "THREAT", "RACE", "RELIGION", "NATIONAL_ETHNIC_ORIGIN",
                                                   "SEXUAL_ORIENTATION", "GENDER", "DISABILITY", "AGE", "OTHER"])
    }

    @Test func metaParses() throws {
        let meta = try Meta.parse(Self.sampleMeta)
        #expect(meta.graph.file == "toxic.tflite" && meta.graph.signature == "serving_default")
        #expect(meta.inputs.map(\.name) == ["embeddings", "attention_mask"] && meta.output.name == "probabilities")
        #expect(meta.table?.cols == 384 && meta.tokenizer.maxLength == 128 && meta.tokenizer.bos == 2 && meta.thresholds["HATEFUL"] == 0.44)
        #expect(throws: ToxicError.self) { try Meta.parse(Self.sampleMeta.replacingOccurrences(of: "\"schema\": 4", with: "\"schema\": 3")) }
    }

    // MARK: through the model

#if !os(WASI)
    @Suite(.serialized, .modelBacked)
    struct ModelTests {
        /// The published artifact against the torch float32 reference: on Apple platforms the Core ML graph, the
        /// table at 4-bit and the layers at 8-bit lookup tables, lands within 0.06 of it on the golden texts; on the
        /// others the LiteRT graph's dynamic int8 layers land within 0.1 (0.081 at v0.2.2, on a target head under
        /// its threshold).
        static let referenceTolerance = ModelPlatform.current == .apple ? 0.06 : 0.1
        /// The graph alone, against torch with the same 4-bit rows: the 8-bit lookup tables land within 0.02, the
        /// dynamic int8 layers within 0.05.
        static let graphTolerance = ModelPlatform.current == .apple ? 0.03 : 0.05
        /// The same artifact against its own probabilities at export, on another machine or compute unit.
        static let artifactTolerance = 0.05

        /// The container encodes every oracle text to the ids the training transform produced.
        @Test func tokenizerMatchesTheOracle() async throws {
            let model = try await makeToxic().loadedModel()
            for entry in try Oracle.load() {
                #expect(model.encode(entry.text) == entry.ids, "\(entry.text.debugDescription)")
            }
        }

        /// The table rows the SDK looks up are the training repository's, value for value.
        @Test func tableRowsMatchTheOracle() async throws {
            let oracle = try TableOracle.load()
            let model = try await makeToxic().loadedModel()
            for entry in oracle.lookups {
                let row = model.row(Int32(entry.id))
                #expect(row.count == oracle.cols)
                #expect(zip(row, entry.row).allSatisfy { abs($0 - Float($1)) <= 1e-6 }, "row \(entry.id)")
            }
        }

        /// The graph on each golden window, fed the ids the goldens carry: against torch with the same rows (the
        /// graph alone), against the float32 reference (the table's rounding included), and against the
        /// artifact's own probabilities at export.
        @Test func windowsMatchTheGoldens() async throws {
            let golden = try Golden.load()
            let model = try await makeToxic().loadedModel()
            let own = golden.artifacts[ToxicModel.directory(for: .current)]
            for (k, ids) in golden.inputIDs.enumerated() {
                let got = try await model.probabilities(ofWindow: ids.filter { $0 != 0 })
                for (h, value) in got.enumerated() {
                    #expect(abs(value - golden.referenceTable[k][h]) < Self.graphTolerance, "text \(k) head \(golden.heads[h]) vs torch with the table's rows")
                    #expect(abs(value - golden.reference[k][h]) < Self.referenceTolerance, "text \(k) head \(golden.heads[h]) vs reference")
                    if let own { #expect(abs(value - own[k][h]) < Self.artifactTolerance, "text \(k) head \(golden.heads[h]) vs the artifact's goldens") }
                }
            }
        }

        /// End to end on the golden texts: a short text is its one window; the text past the window is read in
        /// windows and keeps each head's highest score, so it scores at least its first window.
        @Test func analyzeMatchesTheGoldens() async throws {
            let golden = try Golden.load()
            let toxic = try makeToxic()
            let model = try await toxic.loadedModel()
            for (k, text) in golden.texts.enumerated() {
                let result = try await toxic.analyze(text)
                let single = model.encode(text).count == golden.inputIDs[k].filter { $0 != 0 }.count
                for (h, head) in golden.heads.enumerated() {
                    let label = try #require(Label(rawValue: head))
                    let want = golden.reference[k][h]
                    if single {
                        #expect(abs(result.score(label) - want) < Self.referenceTolerance, "text \(k) \(head)")
                    } else {
                        #expect(result.score(label) >= want - Self.referenceTolerance, "text \(k) \(head)")
                    }
                }
            }
            let hateful = try await toxic.analyze(golden.texts[4])
            #expect(hateful.isToxic && hateful.flagged.contains(.hateful))
            let kind = try await toxic.analyze(golden.texts[0])
            #expect(!kind.isToxic)
            #expect(toxic.isDownloaded())
        }

        /// The default thresholds are the meta's; an option replaces one head's.
        @Test func thresholdsComeFromTheMeta() async throws {
            let toxic = try makeToxic()
            let defaults = try await toxic.defaultThresholds()
            #expect(defaults.count == Label.allCases.count && defaults.values.allSatisfy { (0...1).contains($0) })
            let result = try await toxic.analyze("hello", options: .init(thresholds: [.hateful: 0.0]))
            #expect(result.flagged.contains(.hateful) && result.thresholds[.abusive] == defaults[.abusive])
        }

        /// `TOXIC_MODEL_DIR` points at a local export (the directory layout the Hub revision has) until that
        /// revision is published; without it the suite resolves the pinned revision like every other model's.
        private func makeToxic() throws -> Toxic {
            if let dir = ProcessInfo.processInfo.environment["TOXIC_MODEL_DIR"] {
                return Toxic(directory: dir)
            }
            return Toxic()
        }
    }
#endif

    static let sampleMeta = """
    {"schema": 4, "version": "0.2.1",
     "model": {"id": "toxic", "variant": "litert-mixed", "runtime": "litert", "weights": "x"},
     "graph": {"file": "toxic.tflite", "compute_units": "cpu", "batch": 1, "signature": "serving_default"},
     "inputs": [{"name": "embeddings", "dtype": "float32", "shape": [1, 128, 384]}, {"name": "attention_mask", "dtype": "float32", "shape": [1, 128]}],
     "table": {"file": "toxic_table.bin", "format": "TXTB", "rows": 256000, "cols": 384, "group": 16, "levels": 16, "lookup": "x"},
     "output": {"name": "probabilities", "dtype": "float32", "shape": [1, 11], "heads": ["HATEFUL", "ABUSIVE", "THREAT", "RACE", "RELIGION", "NATIONAL_ETHNIC_ORIGIN", "SEXUAL_ORIENTATION", "GENDER", "DISABILITY", "AGE", "OTHER"]},
     "tokenizer": {"file": "toxic_tokenizer.bin", "format": "TXTK", "max_length": 128, "normalizer": null, "bos": 2, "eos": 1, "pad": 0, "unk": 3, "encoding": "x"},
     "labels": {"content": ["HATEFUL", "ABUSIVE", "THREAT"], "target": ["RACE"]},
     "thresholds": {"HATEFUL": 0.44, "ABUSIVE": 0.43, "THREAT": 0.38}, "thresholds_from": "x", "disabled_heads": []}
    """
}

#if !os(WASI)
struct Golden: Decodable {
    let heads: [String]
    let texts: [String]
    let inputIDs: [[Int32]]
    /// Torch float32 on the ids.
    let reference: [[Double]]
    /// Torch float32 layers on the 4-bit table's rows: what the graph alone is held to.
    let referenceTable: [[Double]]
    /// Each published artifact's probabilities, by its Hub folder.
    let artifacts: [String: [[Double]]]

    enum CodingKeys: String, CodingKey {
        case heads, texts, reference, artifacts
        case inputIDs = "input_ids"
        case referenceTable = "reference_table"
    }

    static func load() throws -> Golden {
        let url = try #require(Bundle.module.url(forResource: "toxic_golden", withExtension: "json"))
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }
}

struct Oracle: Decodable {
    let text: String
    let ids: [Int32]

    static func load() throws -> [Oracle] {
        let url = try #require(Bundle.module.url(forResource: "toxic_tokenizer_oracle", withExtension: "json"))
        return try JSONDecoder().decode([Oracle].self, from: Data(contentsOf: url))
    }
}

struct TableOracle: Decodable {
    struct Lookup: Decodable {
        let id: Int
        let row: [Double]
    }

    let rows: Int
    let cols: Int
    let lookups: [Lookup]

    static func load() throws -> TableOracle {
        let url = try #require(Bundle.module.url(forResource: "toxic_table_oracle", withExtension: "json"))
        return try JSONDecoder().decode(TableOracle.self, from: Data(contentsOf: url))
    }
}
#endif
