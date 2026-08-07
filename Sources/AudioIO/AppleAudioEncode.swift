#if canImport(AVFoundation)
import AVFoundation
import Foundation

// Apple encode backend: AVAudioFile writes whatever container/codec the output
// extension implies (m4a/mp4 -> AAC, caf/aiff -> PCM), converting from the
// float32 samples the pipeline carries. Written in blocks so a long file never
// needs a second full-size buffer: 33 minutes of 48 kHz mono is 363 MB.

extension AudioFileFormat {
    /// The `AVAudioFile` settings dictionary for this encoding. The container
    /// itself comes from the destination's extension.
    internal func settings(sampleRate: Int, channels: Int) -> [String: Any] {
        switch self {
        case .wav:
            return [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false]
        case .aac(let bitRate):
            // A hint, not a contract: AVAudioFile's encoder runs variable rate
            // and routinely lands above the requested figure. It still moves
            // the size meaningfully, so it is worth setting.
            return [AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: bitRate]
        case .pcm:
            return [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false]
        }
    }

    /// Settings to retry with when the primary ones are refused. AAC takes an
    /// explicit bit rate at 48 kHz but rejects one at some lower rates (16 kHz
    /// mono fails in `AudioConverterSetProperty`), so fall back to a
    /// quality-driven encode instead of failing the write.
    internal func fallbackSettings(sampleRate: Int, channels: Int) -> [String: Any]? {
        guard case .aac = self else { return nil }
        return [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
    }
}

extension AudioIO {
    /// Frames pushed per `write`. Large enough that the per-call overhead is
    /// irrelevant, small enough that the staging buffer stays under a megabyte.
    private static let encodeBlockFrames = 1 << 16

    static func appleWrite(_ samples: [Float], sampleRate: Int, channels: Int,
                           to path: String, format: AudioFileFormat) throws {
        let url = URL(fileURLWithPath: path)
        // AVAudioFile refuses to overwrite, and a stale file at the destination
        // would otherwise surface as an opaque CoreAudio error.
        try? FileManager.default.removeItem(at: url)

        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(sampleRate),
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: false) else {
            throw AudioIOError.unsupported("cannot describe \(channels)ch @ \(sampleRate) Hz")
        }

        // `commonFormat`/`interleaved` describe what we hand to `write`;
        // AVAudioFile converts to the file's own encoding on the way out.
        func open(_ settings: [String: Any]) throws -> AVAudioFile {
            try AVAudioFile(forWriting: url, settings: settings,
                            commonFormat: .pcmFormatFloat32, interleaved: false)
        }

        let file: AVAudioFile
        do {
            file = try open(format.settings(sampleRate: sampleRate, channels: channels))
        } catch {
            guard let fallback = format.fallbackSettings(sampleRate: sampleRate, channels: channels) else {
                throw AudioIOError.unsupported("cannot open \(path) for writing: \(error)")
            }
            do { file = try open(fallback) }
            catch { throw AudioIOError.unsupported("cannot open \(path) for writing: \(error)") }
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: source,
                                            frameCapacity: AVAudioFrameCount(encodeBlockFrames)) else {
            throw AudioIOError.unsupported("cannot allocate encode buffer")
        }

        let frames = samples.count / max(1, channels)
        var frame = 0
        while frame < frames {
            let n = min(encodeBlockFrames, frames - frame)
            buffer.frameLength = AVAudioFrameCount(n)
            guard let channelData = buffer.floatChannelData else {
                throw AudioIOError.unsupported("encode buffer has no float storage")
            }
            samples.withUnsafeBufferPointer { sp in
                let base = sp.baseAddress! + frame * channels
                if channels == 1 {
                    channelData[0].update(from: base, count: n)
                } else {
                    // De-interleave: AVAudioPCMBuffer is planar here.
                    for c in 0..<channels {
                        let dst = channelData[c]
                        for i in 0..<n { dst[i] = base[i * channels + c] }
                    }
                }
            }
            do { try file.write(from: buffer) }
            catch { throw AudioIOError.unsupported("write failed at frame \(frame): \(error)") }
            frame += n
        }
    }
}
#endif
