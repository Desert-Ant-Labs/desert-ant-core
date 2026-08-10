#if canImport(AVFoundation)
import AVFoundation

public extension SpeechTimestampRefiner {
    enum AudioFileError: Error, Sendable {
        case cannotAllocateBuffer
        case unsupportedFormat
    }

    /// Create a refiner for SpeechAnalyzer's file-input API, resolving the model on demand
    /// (see `init(locale:directory:)`). A separate file handle is read, so the supplied file
    /// remains positioned for the analyzer.
    convenience init(
        locale: Locale,
        audioFile: AVAudioFile,
        directory: String? = nil,
        maxBufferedSeconds: Double = 30
    ) async throws {
        try await self.init(locale: locale, directory: directory, maxBufferedSeconds: maxBufferedSeconds)
        try loadCompleteAudio(from: audioFile.url)
    }

    /// Create a file-input refiner using resources from an explicit directory.
    convenience init(
        locale: Locale,
        audioFile: AVAudioFile,
        resourceDirectory: URL,
        maxBufferedSeconds: Double = 30
    ) throws {
        try self.init(
            locale: locale,
            resourceDirectory: resourceDirectory,
            maxBufferedSeconds: maxBufferedSeconds
        )
        try loadCompleteAudio(from: audioFile.url)
    }

    /// Feed an audio buffer (any format) into the streaming buffer, converted to 16 kHz mono.
    internal func appendAudio(_ buffer: AVAudioPCMBuffer) {
        if let s = Self.monoFloat(buffer) { appendAudio(s.samples, sampleRate: s.rate) }
    }

    private func loadCompleteAudio(from url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw AudioFileError.cannotAllocateBuffer
        }
        try file.read(into: buffer)
        guard let audio = Self.monoFloat(buffer) else { throw AudioFileError.unsupportedFormat }
        useCompleteAudio(audio.samples, sampleRate: audio.rate)
    }

    internal static func monoFloat(_ buffer: AVAudioPCMBuffer) -> (samples: [Float], rate: Double)? {
        let fmt = buffer.format
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        if let fdata = buffer.floatChannelData {
            let ch = Int(fmt.channelCount)
            var out = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                var acc: Float = 0
                for c in 0..<ch { acc += fdata[c][i] }
                out[i] = acc / Float(ch)
            }
            return (out, fmt.sampleRate)
        }
        if let idata = buffer.int16ChannelData {
            let ch = Int(fmt.channelCount)
            var out = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                var acc: Float = 0
                for c in 0..<ch { acc += Float(idata[c][i]) / 32768.0 }
                out[i] = acc / Float(ch)
            }
            return (out, fmt.sampleRate)
        }
        return nil
    }
}
#endif
