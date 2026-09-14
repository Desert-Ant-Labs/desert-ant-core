#if canImport(CoreML)
import Foundation

/// The streaming half of `meta.json`, nested under `realtime`.
///
/// Separate from ``Configuration`` because the two disagree on keys that mean
/// the same thing: `decode_width` is 8 for a file and 2 for a stream, `n_rows`
/// is a 15 s window against a 160 ms chunk. Flattening them would silently hand
/// one mode the other's geometry, which produces fluent output at the wrong
/// frame offsets rather than an error.
struct LiveConfiguration: Decodable, Sendable {
    /// Encoder frames emitted per dispatch. The latency dial: everything else
    /// here is fixed by the export.
    let chunkFrames: Int
    /// Cached encoder frames attention may read, per layer.
    let leftContext: Int
    /// Hop-sized rows the host hands over per chunk.
    let nRows: Int
    /// Mel frames those rows produce.
    let melFrames: Int
    /// Row index the first chunk starts at. Negative: the model's window opens
    /// before the stream does, which is what `center=True` padding means.
    let firstRowOffset: Int
    /// Rows the window advances per chunk.
    let rowsAdvance: Int
    let chunkSeconds: Double
    let frameSeconds: Double
    /// Audio the model needs from *after* a frame before it can emit it.
    let lookaheadMs: Double
    /// EMA time constant for the running mel statistics.
    let normTauSeconds: Double
    let decodeWidth: Int
    let dModel: Int
    let nLayers: Int
    let convKernel: Int
    /// Whether the streaming graph's weights have been trained for the way it
    /// is wired.
    ///
    /// The streaming and offline functions share their conformer weights, and a
    /// checkpoint trained for full context and centred convolutions does not
    /// transcribe when it is run with a bounded context and causal ones: it
    /// emits almost nothing, and what it does emit is wrong. That is a property
    /// of the weights in the file, so the file is what declares it. Absent
    /// means false, because every bundle built before this field existed is a
    /// converted checkpoint rather than a trained one.
    let trained: Bool?

    enum CodingKeys: String, CodingKey {
        case chunkFrames = "chunk_frames"
        case leftContext = "left_context"
        case nRows = "n_rows"
        case melFrames = "mel_frames"
        case firstRowOffset = "first_row_offset"
        case rowsAdvance = "rows_advance"
        case chunkSeconds = "chunk_seconds"
        case frameSeconds = "frame_seconds"
        case lookaheadMs = "lookahead_ms"
        case normTauSeconds = "norm_tau_seconds"
        case decodeWidth = "decode_width"
        case dModel = "d_model"
        case nLayers = "n_layers"
        case convKernel = "conv_kernel"
        case trained
    }

    /// Whether the low-latency pass is worth running at all.
    var streamingUsable: Bool { trained == true }

    /// Channels in each cache tensor: every layer's hidden width, stacked.
    ///
    /// Stacked on the channel axis rather than a leading layer axis because
    /// that keeps the tensor rank 4, and the Neural Engine's rank limit is 5
    /// with nothing to spare once batch and width are counted.
    var cacheChannels: Int { nLayers * dModel }

    /// Samples that must have arrived before chunk `index` can run.
    func samplesNeeded(chunk index: Int, hopLength: Int, nFFT: Int) -> Int {
        (firstRowOffset + rowsAdvance * index + nRows) * hopLength - nFFT / 2
    }

    /// Stream index of the earliest sample chunk `index` reads. Negative at the
    /// start of a stream, where the host supplies zeros.
    func firstSample(chunk index: Int, hopLength: Int, nFFT: Int) -> Int {
        (firstRowOffset + rowsAdvance * index) * hopLength - nFFT / 2
    }

    func validate() throws {
        guard chunkFrames > 0, leftContext > 0, nRows > 0, melFrames > 0,
              rowsAdvance > 0, dModel > 0, nLayers > 0, convKernel > 1,
              decodeWidth > 0, chunkSeconds > 0, frameSeconds > 0
        else { throw VozError.invalidModel("realtime metadata has invalid geometry") }
        // The subsampling receptive field: encoder frame o sees mel [8o-7, 8o+7],
        // so a chunk of C frames spans 8C+7 and needs 3 more rows for the DFT
        // window plus 1 for pre-emphasis. A mismatch here is a one-frame
        // misalignment that still transcribes, which is the worst kind.
        guard melFrames == 8 * chunkFrames + 7 else {
            throw VozError.invalidModel(
                "realtime mel_frames \(melFrames) != 8 * \(chunkFrames) + 7")
        }
        guard nRows == melFrames + 4 else {
            throw VozError.invalidModel("realtime n_rows \(nRows) != mel_frames + 4")
        }
        guard rowsAdvance == 8 * chunkFrames else {
            throw VozError.invalidModel("realtime rows_advance != 8 * chunk_frames")
        }
    }
}
#endif
