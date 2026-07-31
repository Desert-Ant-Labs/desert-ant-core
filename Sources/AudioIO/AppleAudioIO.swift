#if canImport(AVFoundation)
import AVFoundation
import Foundation

// Apple decode backend: AVFoundation reads any supported container/codec, and
// AVAudioConverter mixes to mono and resamples to the target rate in one pass.
// In-memory bytes are staged to a temp file because AVAudioFile reads from a URL.

extension AudioIO {
    static func appleDecode(path: String?, bytes: [UInt8]?, sampleRate: Double) throws -> [Float] {
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
            guard
                let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: sampleRate, channels: 1, interleaved: false),
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
            var fed = false
            var error: NSError?
            converter.convert(to: outBuffer, error: &error) { _, status in
                if fed { status.pointee = .endOfStream; return nil }
                fed = true; status.pointee = .haveData; return inBuffer
            }
            if let error { throw error }
            guard let channel = outBuffer.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
        } catch let e as AudioIOError {
            throw e
        } catch {
            throw AudioIOError.decodeFailed("\(error)")
        }
    }
}
#endif
