#if canImport(CoreML)
import CoreML
import Foundation

/// Model geometry, read from the export rather than assumed.
///
/// Every field here was hardcoded at some point and caused a bug: a window
/// length mismatch silently misframed audio, and a missing `nFFT` dropped the
/// centering pad and shifted every frame by 256 samples while still producing
/// fluent output.
struct Configuration: Decodable, Sendable {
    let sampleRate: Int
    let hopLength: Int
    let nSamples: Int
    let nRows: Int
    let nMels: Int
    let nFFT: Int
    let preemph: Float
    let nPaddedSamples: Int
    let validFrames: Int
    let encFrames: Int
    let jointHidden: Int
    let predHidden: Int
    let predLayers: Int
    let vocabSize: Int
    let blankIdx: Int
    let durations: [Int]
    let decodeWidth: Int

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case hopLength = "hop_length"
        case nSamples = "n_samples"
        case nRows = "n_rows"
        case nMels = "n_mels"
        case nFFT = "n_fft"
        case preemph
        case nPaddedSamples = "n_padded_samples"
        case validFrames = "valid_frames"
        case encFrames = "enc_frames"
        case jointHidden = "joint_hidden"
        case predHidden = "pred_hidden"
        case predLayers = "pred_layers"
        case vocabSize = "vocab_size"
        case blankIdx = "blank_idx"
        case durations
        case decodeWidth = "decode_width"
    }

    /// Seconds of audio per encoder frame: the resolution of every word time.
    var secondsPerFrame: Double { Double(hopLength * 8) / Double(sampleRate) }

    func validate() throws {
        guard sampleRate > 0, hopLength > 0, nSamples > 0, nRows > 0, nMels > 0,
              nFFT > 0, encFrames > 0, jointHidden > 0, predHidden > 0, predLayers > 0
        else { throw ScribeError.invalidModel("model metadata has invalid geometry") }
        guard vocabSize > 0, blankIdx >= 0, blankIdx <= vocabSize, !durations.isEmpty
        else { throw ScribeError.invalidModel("model metadata has an invalid vocabulary") }
        guard decodeWidth > 0, nPaddedSamples >= nSamples
        else { throw ScribeError.invalidModel("model metadata has invalid decode geometry") }
    }
}
#endif
