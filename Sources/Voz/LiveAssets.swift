#if canImport(CoreML)
import CoreML
import Foundation

/// The streaming half of the model: two functions of the shared programs.
///
/// `encoder.mlmodelc` and `decoder.mlmodelc` are multifunction packages whose
/// `offline` and `realtime` functions share their conformer weights, so the
/// streaming capability is a few megabytes on top of the offline bundle rather
/// than a second download. Reaching a function needs
/// `MLModelConfiguration.functionName`, which is why this half of the SDK
/// carries an availability floor the offline half does not.
///
/// A bundle whose models are single-function still loads: ``load`` falls back to
/// the default function, which is what an older export is.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, visionOS 2.0, *)
struct LiveAssets {
    let configuration: Configuration
    let live: LiveConfiguration
    let vocabulary: [String]
    let encoder: MLModel
    let decodeStep: MLModel
    private let embeddingData: Data

    init(directory: URL, computeUnits: MLComputeUnits) throws {
        let decoder = JSONDecoder()
        let metaURL = directory.appendingPathComponent("meta.json")
        let metaData = try Data(contentsOf: metaURL)
        configuration = try decoder.decode(Configuration.self, from: metaData)
        try configuration.validate()

        guard let envelope = try? decoder.decode(Envelope.self, from: metaData),
              let realtime = envelope.realtime else {
            throw VozError.invalidModel(
                "this model build has no realtime function, so Voz.Live is "
                    + "unavailable; Voz.transcribe works with it")
        }
        live = realtime
        try live.validate()

        vocabulary = try decoder.decode(
            [String].self,
            from: try Data(contentsOf: directory.appendingPathComponent("vocab.json")))
        guard vocabulary.count >= configuration.vocabSize else {
            throw VozError.invalidModel("vocabulary is smaller than the model's vocab size")
        }

        let raw = try Data(contentsOf: directory.appendingPathComponent("embedding.f16"),
                           options: .mappedIfSafe)
        let expected = (configuration.vocabSize + 1) * configuration.predHidden
        guard raw.count == expected * MemoryLayout<Element>.size else {
            throw VozError.invalidModel(
                "embedding.f16 has \(raw.count) bytes, expected \(expected * 2)")
        }
        embeddingData = raw

        let names = envelope.functions
        encoder = try Self.load(
            directory.appendingPathComponent(VozModel.encoder),
            function: names?.encoder?.realtime ?? VozModel.realtimeFunction,
            computeUnits: computeUnits)
        decodeStep = try Self.load(
            directory.appendingPathComponent(VozModel.decodeStep),
            function: names?.decoder?.realtime ?? VozModel.realtimeFunction,
            computeUnits: computeUnits)
        try check(encoder, has: "rows", named: "encoder")
        try check(decodeStep, has: "enc_step", named: "decoder")
    }

    /// A function was requested but the model does not declare it, which means
    /// the file is an offline-only export and every prediction would silently be
    /// the wrong graph. Caught at load rather than at the first chunk.
    private func check(_ model: MLModel, has input: String, named: String) throws {
        guard model.modelDescription.inputDescriptionsByName[input] != nil else {
            throw VozError.invalidModel(
                "\(named) has no '\(input)' input: this is not a realtime function")
        }
    }

    private static func load(_ url: URL, function: String?,
                             computeUnits: MLComputeUnits) throws -> MLModel {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VozError.invalidModel("missing \(url.lastPathComponent)")
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        if let function {
            configuration.functionName = function
        }
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    func withEmbedding<T>(_ body: (UnsafeBufferPointer<Element>) throws -> T) rethrows -> T {
        try embeddingData.withUnsafeBytes { try body($0.bindMemory(to: Element.self)) }
    }

    // MARK: - meta.json shape

    private struct Envelope: Decodable {
        let realtime: LiveConfiguration?
        let functions: Functions?
    }

    struct Functions: Decodable {
        let encoder: Pair?
        let decoder: Pair?
        struct Pair: Decodable {
            let offline: String?
            let realtime: String?
        }
    }
}
#endif
