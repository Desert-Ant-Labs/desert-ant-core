#if canImport(AVFoundation)
// `@preconcurrency`: AVAudioConverter's input block is documented to run
// synchronously, before `convert(to:error:)` returns, but AVFAudio predates
// concurrency annotations and the block is typed `@Sendable`. Without this the
// Swift 6 language mode flags the buffer it hands back and the "already fed" flag
// it flips, neither of which ever leaves this call.
@preconcurrency import AVFoundation
import Foundation

// Apple decode backend: AVFoundation reads any supported container/codec, and
// AVAudioConverter mixes to mono and resamples to the target rate in one pass.
// In-memory bytes are staged to a temp file because AVAudioFile reads from a URL.

extension AudioIO {
    static func appleDecode(path: String?, bytes: [UInt8]?, sampleRate: Double) throws -> [Float] {
        try appleDecodeChannels(path: path, bytes: bytes, sampleRate: sampleRate, channels: 1).first ?? []
    }

    /// As `appleDecode`, but keeping `channels` of them - or the file's own
    /// layout when `channels` is nil. One channel is the mixdown, which is what
    /// the mono entry point asks for.
    static func appleDecodeChannels(path: String?, bytes: [UInt8]?, sampleRate: Double,
                                    channels requested: Int?) throws -> [[Float]] {
        let url: URL
        var temp: URL?
        if let path {
            url = URL(fileURLWithPath: path)
        } else if let bytes {
            let t = FileManager.default.temporaryDirectory
                .appendingPathComponent("dal-audio-\(UUID().uuidString)")
            try Data(bytes).write(to: t)
            url = t
            temp = t
        } else {
            throw AudioIOError.decodeFailed("no path or bytes")
        }
        defer { if let temp { try? FileManager.default.removeItem(at: temp) } }

        do {
            let file = try AVAudioFile(forReading: url)
            let inFormat = file.processingFormat
            let inChannels = Int(inFormat.channelCount)
            // nil means "whatever the file has". The converter is only trusted
            // to change channel count for mono/stereo material: beyond stereo
            // AVAudioConverter has no downmix matrix and silently keeps channel
            // 0 (a 14-channel field recording decoded to just its first mic),
            // so a many-channel mixdown converts at the source layout and
            // averages below, the same mixdown the portable path uses.
            let outChannels = requested ?? inChannels
            let mixdownAfter = outChannels == 1 && inChannels > 2
            let convChannels = AVAudioChannelCount(mixdownAfter ? inChannels : outChannels)
            // The channels-count initializer returns nil beyond stereo; many-
            // channel formats need an explicit layout. Prefer the file's own,
            // fall back to "N discrete channels in order".
            let outFormat: AVAudioFormat?
            if convChannels <= 2 {
                outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: sampleRate, channels: convChannels,
                                          interleaved: false)
            } else if let layout = inFormat.channelLayout
                ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(convChannels)) {
                outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: sampleRate, interleaved: false,
                                          channelLayout: layout)
            } else {
                outFormat = nil
            }
            guard
                convChannels > 0, outChannels > 0, file.length > 0,
                let outFormat,
                let converter = AVAudioConverter(from: inFormat, to: outFormat)
            else { throw AudioIOError.decodeFailed("cannot build converter") }

            // Chunked, not whole-file: converting a multi-GB file in one call
            // needs input, intermediate and output buffers sized to the whole
            // file at once, and AVFoundation's internal byte counts are 32-bit
            // (a 2.2 GB 14-channel wav died with std::overflow_error). A fixed
            // chunk keeps every buffer small no matter the file.
            let chunkFrames: AVAudioFrameCount = 1 << 19  // ~0.5M frames per read
            let outCapacity = AVAudioFrameCount(Double(chunkFrames) * max(1, sampleRate / inFormat.sampleRate) + 4096)
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunkFrames),
                  let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity)
            else { throw AudioIOError.decodeFailed("cannot build buffers") }

            var channelsOut = [[Float]](repeating: [], count: Int(convChannels))
            var drained = false
            while !drained {
                inBuffer.frameLength = 0
                // Reading at EOF throws eofErr rather than returning 0 frames,
                // so stop by position instead of probing.
                if file.framePosition < file.length {
                    try file.read(into: inBuffer, frameCount: chunkFrames)
                }
                let last = inBuffer.frameLength == 0
                // `nonisolated(unsafe)` for the same reason as `@preconcurrency`
                // above: the block runs synchronously inside `convert`, on this
                // thread, so there is no concurrency for the flag to be unsafe
                // across.
                nonisolated(unsafe) var fed = false
                var error: NSError?
                let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                    if fed || last { outStatus.pointee = last ? .endOfStream : .noDataNow; return nil }
                    fed = true; outStatus.pointee = .haveData; return inBuffer
                }
                if let error { throw error }
                if status == .endOfStream { drained = true }
                if let data = outBuffer.floatChannelData {
                    let frames = Int(outBuffer.frameLength)
                    // Non-interleaved, so each channel is its own contiguous buffer.
                    for c in 0..<Int(convChannels) {
                        channelsOut[c].append(contentsOf: UnsafeBufferPointer(start: data[c], count: frames))
                    }
                }
                outBuffer.frameLength = 0
            }

            guard mixdownAfter else { return channelsOut }
            // Average the source channels into mono, matching Resample.mixdownMono.
            let frames = channelsOut[0].count
            var mono = [Float](repeating: 0, count: frames)
            let inv = 1 / Float(channelsOut.count)
            for channel in channelsOut {
                for i in 0..<min(frames, channel.count) { mono[i] += channel[i] }
            }
            for i in 0..<frames { mono[i] *= inv }
            return [mono]
        } catch let e as AudioIOError {
            throw e
        } catch {
            throw AudioIOError.decodeFailed("\(error)")
        }
    }
}
#endif
