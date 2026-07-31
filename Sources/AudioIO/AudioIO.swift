// One audio decode/encode API with a per-platform backend behind it, so an
// audio model SDK never writes AVFoundation, MediaCodec, or Web Audio code:
//
//   Apple      AVFoundation (AVAudioFile + AVAudioConverter)
//   Android    host MediaExtractor/MediaCodec via CHostBridge host_audio_decode
//   WebAssembly  AudioContext.decodeAudioData via the JS host global
//   Linux/other  the pure-Swift WAV codec + linear resample
//
// `decode` always returns mono `Float` at the requested sample rate, ready to
// feed a model (or AudioDSP). It is `async` because the wasm backend awaits a
// JS Promise; the native backends satisfy it synchronously. Encoding a 16-bit
// PCM WAV is pure Swift, identical on every platform.

public enum AudioIOError: Error, Sendable {
    case decodeFailed(String)
    case unsupported(String)
}

public enum AudioIO {
    /// Decode the audio file at `path` to mono `Float` samples at
    /// `sampleRate`, resampling and mixing to mono as needed.
    public static func decode(path: String, sampleRate: Double) async throws -> [Float] {
        #if canImport(AVFoundation)
        return try appleDecode(path: path, bytes: nil, sampleRate: sampleRate)
        #elseif os(Android)
        return try hostDecode(path: path, bytes: nil, sampleRate: sampleRate)
        #elseif os(WASI)
        return try await jsDecode(path: path, bytes: nil, sampleRate: sampleRate)
        #else
        return try portableDecode(bytes: readFile(path), sampleRate: sampleRate)
        #endif
    }

    /// Decode an in-memory audio file (any container the platform supports; the
    /// portable path is WAV) to mono `Float` at `sampleRate`.
    public static func decode(bytes: [UInt8], sampleRate: Double) async throws -> [Float] {
        #if canImport(AVFoundation)
        return try appleDecode(path: nil, bytes: bytes, sampleRate: sampleRate)
        #elseif os(Android)
        return try hostDecode(path: nil, bytes: bytes, sampleRate: sampleRate)
        #elseif os(WASI)
        return try await jsDecode(path: nil, bytes: bytes, sampleRate: sampleRate)
        #else
        return try portableDecode(bytes: bytes, sampleRate: sampleRate)
        #endif
    }

    /// Encode mono (or interleaved) `samples` in `[-1, 1]` as a 16-bit PCM WAV
    /// byte buffer. Portable and identical on every platform.
    public static func encodeWAV(_ samples: [Float], sampleRate: Int, channels: Int = 1) -> [UInt8] {
        WAV.encode(samples, sampleRate: sampleRate, channels: channels)
    }

    /// Decode WAV bytes with the pure-Swift codec, mixing to mono and
    /// resampling to `sampleRate`. The portable-path implementation, exposed so
    /// a caller can force the WAV codec regardless of platform.
    static func portableDecode(bytes: [UInt8], sampleRate: Double) throws -> [Float] {
        do {
            let pcm = try WAV.decode(bytes)
            return Resample.toMono(pcm, sampleRate: sampleRate)
        } catch {
            throw AudioIOError.decodeFailed("\(error)")
        }
    }
}

#if canImport(Foundation) && !os(Android) && !os(WASI)
import Foundation

public extension AudioIO {
    /// Write mono (or interleaved) `samples` as a 16-bit PCM WAV file. Uses the
    /// portable encoder, so the bytes match `encodeWAV`. Available where a
    /// filesystem is (Apple/Linux); on Android/wasm write through the host.
    static func writeWAV(_ samples: [Float], sampleRate: Int, channels: Int = 1, to path: String) throws {
        let bytes = WAV.encode(samples, sampleRate: sampleRate, channels: channels)
        try Data(bytes).write(to: URL(fileURLWithPath: path))
    }
}

extension AudioIO {
    static func readFile(_ path: String) throws -> [UInt8] {
        do { return try [UInt8](Data(contentsOf: URL(fileURLWithPath: path))) }
        catch { throw AudioIOError.decodeFailed("read \(path): \(error)") }
    }
}
#endif
