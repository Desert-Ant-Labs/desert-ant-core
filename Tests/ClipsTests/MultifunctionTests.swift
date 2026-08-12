#if canImport(CoreML) && !os(WASI)
import Foundation
import Testing
import DesertAnt
@_spi(ClipBindings) @testable import Clips

/// Opening the Apple artifact, which is ONE `.mlmodelc` carrying the selector
/// and the scorer as the Core ML functions `select` and `score`.
///
/// The fixture is a 24 KB weightless package with the exports' real signature
/// (`ids`/`mask`/`disc` in, `saliency`/`start_p`/`end_p` and `score` out) and
/// `select` as its default function, so it reproduces the property that matters
/// without the shipping 281 MB asset: a path names the file, not the graph. Ask
/// Core ML for a model without naming a function and it hands back the default
/// one and reports nothing, which is why loading is worth a test of its own.
@Suite(.enabled(if: supportsMultifunction, "multifunction packages need iOS 18 / macOS 15"))
struct ClipMultifunctionTests {
    /// The whole pipeline over one asset: `ModelAssets.clip(files:)` opens both
    /// halves out of the single declared file and `Model` runs them.
    ///
    /// Without the function name threaded through this cannot work at all, so
    /// this test is the proof that the shipping package is loadable: the second
    /// session would be the selector again, and the scorer's `score` output
    /// does not exist on that graph.
    @Test func bothHalvesLoadFromOneAssetAndSelectionRunsEndToEnd() async throws {
        let files = try resolvedModelDirectory()
        defer { try? FileManager.default.removeItem(atPath: files.rootPath) }

        let model = try Model(assets: await ModelAssets.clip(files: files))
        let transcript = (0..<12).map { "sentence number \($0) with words of its own \($0)" }
        let moments = try await model.clips(in: transcript, limit: nil)

        #expect(!moments.isEmpty, "one asset, two functions, a full selection pass")
        #expect(moments.map(\.score) == moments.map(\.score).sorted(by: >), "best first")
        for moment in moments {
            #expect(moment.sentenceIDs.allSatisfy { transcript.indices.contains($0) })
        }
    }

    /// The defect, stated as a test. Loaded with no function name the package
    /// answers as `select`: it returns saliency perfectly happily and has no
    /// `score` to give. Nothing at load says which graph came back, which is
    /// the part worth pinning - that these two signatures differ is only what
    /// turns the mistake into an error later instead of a wrong number.
    @Test func withoutAFunctionNameThePackageIsItsDefaultFunction() async throws {
        let files = try resolvedModelDirectory()
        defer { try? FileManager.default.removeItem(atPath: files.rootPath) }
        let path = files.path(ClipModel.coreML)

        let unnamed = try inferenceSession(modelPath: path)
        let asSelector = try await unnamed.run(inputs: selectorInputs, outputs: ["saliency"])
        #expect(asSelector.first?.float32Values?.count == Model.batch,
                "the default function is the selector")
        await #expect(throws: (any Error).self) {
            _ = try await unnamed.run(inputs: scorerInputs, outputs: ["score"])
        }

        let scorer = try inferenceSession(modelPath: path, functionName: ClipModel.scoreFunction)
        let scores = try await scorer.run(inputs: scorerInputs, outputs: ["score"])
        #expect(scores.first?.float32Values?.count == Model.batch)
    }

    /// A name the asset does not carry must fail at load. Falling back to the
    /// default would be the same wrong graph as above, under a name that looks
    /// addressed.
    @Test func anUnknownFunctionIsRejected() throws {
        let files = try resolvedModelDirectory()
        defer { try? FileManager.default.removeItem(atPath: files.rootPath) }
        #expect(throws: (any Error).self) {
            _ = try inferenceSession(modelPath: files.path(ClipModel.coreML),
                                     functionName: "rank")
        }
    }

    // MARK: the fixture, laid out the way a resolved model directory is

    /// The multifunction fixture under the name ``ClipModel/coreML`` declares,
    /// plus the tokenizer sidecar, so `ModelAssets.clip(files:)` reads exactly
    /// what it reads in production.
    private func resolvedModelDirectory() throws -> StoredModel {
        let fixture = try #require(
            Bundle.module.url(forResource: "clips-multifunction", withExtension: "mlmodelc"))
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clips-multifunction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture, to: root.appendingPathComponent(ClipModel.coreML))
        try Data(syntheticVocab()).write(to: root.appendingPathComponent(ClipModel.tokenizer))
        return try StoredModel.platformLocal(rootPath: root.path)
    }

    /// The two functions run at DIFFERENT widths, so these are built independently.
    /// `selectorInputs` used to be `scorerInputs` plus `disc`, which only worked
    /// while both graphs shared a sequence length — a coupling that would have
    /// silently produced a wrong-shaped selector batch the moment one moved.
    private var selectorInputs: [String: Tensor] {
        let count = Model.batch * Model.seqLen
        return ["ids": Tensor(int32: [Int32](repeating: 5, count: count),
                              shape: [Model.batch, Model.seqLen]),
                "mask": Tensor(int32: [Int32](repeating: 1, count: count),
                               shape: [Model.batch, Model.seqLen]),
                "disc": Tensor(float32: [Float](repeating: 0, count: Model.batch * 5),
                               shape: [Model.batch, 5])]
    }

    /// At the SCORER's width. This also sharpens the negative case: feeding these
    /// to the default (selector) function now fails on shape as well as on the
    /// missing `score` output, which is the confusion a two-shape package invites.
    private var scorerInputs: [String: Tensor] {
        let count = Model.batch * Model.scoreSeqLen
        return ["ids": Tensor(int32: [Int32](repeating: 5, count: count),
                              shape: [Model.batch, Model.scoreSeqLen]),
                "mask": Tensor(int32: [Int32](repeating: 1, count: count),
                               shape: [Model.batch, Model.scoreSeqLen])]
    }
}

/// `MLModelConfiguration.functionName` is iOS 18 / macOS 15, and this package
/// deploys back to iOS 16 / macOS 13, so the suite is a runtime condition rather
/// than a `#if` - a skipped run is reported as skipped.
private let supportsMultifunction: Bool = {
    if #available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, *) { return true }
    return false
}()
#endif
