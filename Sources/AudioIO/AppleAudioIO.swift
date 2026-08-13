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
            // nil means "whatever the file has"; the converter downmixes when
            // asked for fewer channels than the source carries.
            let outChannels = AVAudioChannelCount(requested ?? Int(inFormat.channelCount))
            guard
                outChannels > 0,
                let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: sampleRate, channels: outChannels,
                                              interleaved: false),
                let converter = AVAudioConverter(from: inFormat, to: outFormat),
                file.length > 0,
                let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat,
                                                frameCapacity: AVAudioFrameCount(file.length))
            else { throw AudioIOError.decodeFailed("cannot build converter") }

            try file.read(into: inBuffer)
            let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * (sampleRate / inFormat.sampleRate) + 4096)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
                throw AudioIOError.decodeFailed("cannot build output buffer")
            }
            // `nonisolated(unsafe)` for the same reason as `@preconcurrency` above:
            // the block that flips this runs synchronously inside `convert`, on this
            // thread, so there is no concurrency for the flag to be unsafe across.
            nonisolated(unsafe) var fed = false
            var error: NSError?
            converter.convert(to: outBuffer, error: &error) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true; status.pointee = .haveData; return inBuffer
            }
            if let error { throw error }
            guard let data = outBuffer.floatChannelData else { return [] }
            let frames = Int(outBuffer.frameLength)
            // Non-interleaved, so each channel is its own contiguous buffer.
            return (0..<Int(outChannels)).map {
                Array(UnsafeBufferPointer(start: data[$0], count: frames))
            }
        } catch let e as AudioIOError {
            throw e
        } catch {
            throw AudioIOError.decodeFailed("\(error)")
        }
    }
}
#endif
