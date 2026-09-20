#if canImport(AVFoundation) && canImport(Speech) && canImport(CoreMedia)
import AVFoundation
import DesertAnt

public extension StreamingRefiner {
    enum AudioFileError: Error, Sendable {
        case cannotAllocateBuffer
        case unsupportedFormat
    }

    /// Create a refiner for SpeechAnalyzer's file-input API. A separate file handle is read,
    /// so the supplied file remains positioned for the analyzer.
    convenience init(
        locale: Locale,
        audioFile: AVAudioFile,
        directory: String? = nil,
        maxBufferedSeconds: Double = 30,
        computeUnits: ComputeUnits = .cpuAndNeuralEngine
    ) async throws {
        self.init(locale: locale, directory: directory, maxBufferedSeconds: maxBufferedSeconds,
                  computeUnits: computeUnits)
        try await loadCompleteAudio(from: audioFile.url)
    }

    /// Feed an audio buffer (any format) into the streaming buffer, converted to 16 kHz mono.
    internal func appendAudio(_ buffer: AVAudioPCMBuffer) async throws {
        if let s = Self.monoFloat(buffer) { try await appendAudio(s.samples, sampleRate: s.rate) }
    }

    private func loadCompleteAudio(from url: URL) async throws {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw AudioFileError.cannotAllocateBuffer
        }
        try file.read(into: buffer)
        guard let audio = Self.monoFloat(buffer) else { throw AudioFileError.unsupportedFormat }
        try await useCompleteAudio(audio.samples, sampleRate: audio.rate)
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
