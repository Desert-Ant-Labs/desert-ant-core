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

/// The output encodings ``AudioIO/write(_:sampleRate:channels:to:)`` can
/// produce, chosen from the destination's path extension.
public enum AudioFileFormat: Sendable, Equatable {
    /// 16-bit PCM WAV. The portable encoding: available on every platform.
    case wav
    /// AAC in an MPEG-4 container (`.m4a`, `.mp4`, `.aac`). Apple only.
    case aac(bitRate: Int)
    /// Uncompressed PCM in a CAF or AIFF container. Apple only.
    case pcm

    /// Maps a path extension onto an encoding. Unknown extensions are `nil`, so
    /// a caller can decide between defaulting and rejecting.
    public static func inferred(fromPathExtension ext: String) -> AudioFileFormat? {
        switch ext.lowercased() {
        case "wav", "wave": .wav
        case "m4a", "mp4", "aac": .aac(bitRate: 128_000)
        case "caf", "aif", "aiff": .pcm
        default: nil
        }
    }
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
    /// Streams the file out in fixed-size blocks. Encoding to `[UInt8]` and then
    /// copying into `Data` held two more full-size buffers (about 362 MB
    /// combined for 33 minutes of 48 kHz mono) on top of the samples.
    static func writeWAV(_ samples: [Float], sampleRate: Int, channels: Int = 1, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.createFile(atPath: path, contents: nil) else {
            throw AudioIOError.decodeFailed("cannot create \(path)")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        try handle.write(contentsOf: WAV.header(sampleCount: samples.count,
                                                sampleRate: sampleRate, channels: channels))
        let blockSamples = 1 << 16
        var block = [UInt8]()
        block.reserveCapacity(blockSamples * 2)
        var index = samples.startIndex
        while index < samples.endIndex {
            let end = min(index + blockSamples, samples.endIndex)
            block.removeAll(keepingCapacity: true)
            WAV.appendPCM16(samples[index..<end], to: &block)
            try handle.write(contentsOf: block)
            index = end
        }
    }
}

public extension AudioIO {
    /// Write `samples` to `path`, choosing the encoding from the path extension
    /// (`.wav` -> 16-bit PCM, `.m4a`/`.mp4`/`.aac` -> AAC, `.caf`/`.aiff` ->
    /// PCM). Unrecognized extensions fall back to `defaultFormat`.
    ///
    /// Only `.wav` exists off Apple platforms; anything else throws
    /// `AudioIOError.unsupported` there rather than silently writing WAV bytes
    /// under a misleading extension.
    static func write(_ samples: [Float], sampleRate: Int, channels: Int = 1,
                      to path: String, defaultFormat: AudioFileFormat = .wav) throws {
        let ext = URL(fileURLWithPath: path).pathExtension
        let format = AudioFileFormat.inferred(fromPathExtension: ext) ?? defaultFormat
        switch format {
        case .wav:
            try writeWAV(samples, sampleRate: sampleRate, channels: channels, to: path)
        case .aac, .pcm:
            #if canImport(AVFoundation)
            try appleWrite(samples, sampleRate: sampleRate, channels: channels,
                           to: path, format: format)
            #else
            throw AudioIOError.unsupported("\(ext) encoding needs AVFoundation; only WAV is portable")
            #endif
        }
    }
}

extension AudioIO {
    static func readFile(_ path: String) throws -> [UInt8] {
        do { return try [UInt8](Data(contentsOf: URL(fileURLWithPath: path))) }
        catch { throw AudioIOError.decodeFailed("read \(path): \(error)") }
    }
}
#endif
