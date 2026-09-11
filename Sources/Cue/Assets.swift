#if canImport(CoreML)
import CoreML
import Foundation

/// Geometry the runtime refuses to hardcode, read from `cue_meta.json` beside
/// the model so re-exporting the network cannot silently disagree with the
/// frontend that feeds it.
struct Configuration: Codable, Sendable {
    let model: String
    let input: String
    let output: String
    let sampleRate: Int
    let frameLengthSamples: Int
    let frameShiftSamples: Int
    let nFFT: Int
    let mels: Int
    let melLowHz: Double
    let melHighHz: Double
    let preemphasis: Float
    /// Frames per Core ML call. The graph is a fixed shape: the Neural Engine
    /// has no dynamic shapes, and an enumerated-shape model would not stay
    /// resident on it.
    let windowFrames: Int
    /// The DFSMN receptive field. A window handed this many real frames of
    /// context on each side produces output identical to running the whole
    /// utterance at once, which is what makes chunking exact rather than
    /// approximate.
    let lookbackFrames: Int
    let lookaheadFrames: Int
    let defaults: Defaults

    struct Defaults: Codable, Sendable {
        let smoothWindowFrames: Int
        let speechThreshold: Float
        let minSpeechFrames: Int
        let maxSpeechFrames: Int
        let minSilenceFrames: Int
        let mergeSilenceFrames: Int
        let extendSpeechFrames: Int
    }

    var frameShiftSeconds: Double { Double(frameShiftSamples) / Double(sampleRate) }

    func validate() throws {
        guard sampleRate > 0, mels > 0, windowFrames > 0 else {
            throw CueError.invalidModel("meta has non-positive geometry")
        }
        guard windowFrames > lookbackFrames + lookaheadFrames else {
            throw CueError.invalidModel(
                "window of \(windowFrames) frames cannot hold "
                    + "\(lookbackFrames)+\(lookaheadFrames) frames of context")
        }
    }

    var frontendGeometry: Frontend.Geometry {
        .init(sampleRate: sampleRate, frameLengthSamples: frameLengthSamples,
              frameShiftSamples: frameShiftSamples, nFFT: nFFT, mels: mels,
              melLowHz: melLowHz, melHighHz: melHighHz, preemphasis: preemphasis)
    }
}

/// The loaded model plus the frontend that feeds it.
struct Assets {
    let configuration: Configuration
    let frontend: Frontend
    let model: MLModel

    init(directory: URL, computeUnits: MLComputeUnits) throws {
        let metaURL = directory.appendingPathComponent(CueModel.meta)
        guard let metaData = try? Data(contentsOf: metaURL) else {
            throw CueError.invalidModel("missing \(CueModel.meta) in \(directory.path)")
        }
        configuration = try JSONDecoder().decode(Configuration.self, from: metaData)
        try configuration.validate()
        frontend = try Frontend(geometry: configuration.frontendGeometry)

        let modelURL = directory.appendingPathComponent(configuration.model)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw CueError.invalidModel("missing \(configuration.model) in \(directory.path)")
        }
        let mlConfiguration = MLModelConfiguration()
        mlConfiguration.computeUnits = computeUnits
        model = try MLModel(contentsOf: modelURL, configuration: mlConfiguration)

        // The window is a compiled-in constant of the graph, so disagreeing with
        // the meta would mis-slice every chunk. Read it back and check.
        guard let input = model.modelDescription
            .inputDescriptionsByName[configuration.input],
            let constraint = input.multiArrayConstraint else {
            throw CueError.invalidModel("model has no \(configuration.input) input")
        }
        let shape = constraint.shape.map(\.intValue)
        guard shape.count == 4, shape[1] == configuration.mels,
              shape[3] == configuration.windowFrames else {
            throw CueError.invalidModel(
                "model takes \(shape), meta says [1, \(configuration.mels), 1, "
                    + "\(configuration.windowFrames)]")
        }
    }
}
#endif
