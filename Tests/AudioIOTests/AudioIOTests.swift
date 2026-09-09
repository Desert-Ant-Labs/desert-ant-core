import Testing
import Foundation
import TestSupport
@testable import AudioIO

struct AudioIOTests {
    private func tone(_ n: Int, freq: Double = 440, sr: Double = 16000) -> [Float] {
        (0..<n).map { Float(0.5 * sin(2 * .pi * freq * Double($0) / sr)) }
    }

    @Test func wavRoundTrip16Bit() throws {
        let x = tone(4000)
        let bytes = WAV.encode(x, sampleRate: 16000, channels: 1)
        let pcm = try WAV.decode(bytes)
        #expect(pcm.sampleRate == 16000)
        #expect(pcm.channels == 1)
        #expect(pcm.samples.count == x.count)
        // 16-bit quantization error is bounded by ~1/32768.
        var maxErr: Float = 0
        for i in 0..<x.count { maxErr = max(maxErr, abs(x[i] - pcm.samples[i])) }
        #expect(maxErr < 1e-3)
    }

    // AudioIO.decode / writeWAV route through the platform backend: the
    // AVFoundation/portable-WAV path on Apple/Linux, but the JS host on wasm
    // (which isn't installed in the Swift test harness) and a filesystem the
    // WASI sandbox lacks. The wasm decode path is covered by js/test/audio.test.mjs
    // (installAudioHost). These exercise the native/portable path only.
    #if !os(WASI)
    @Test func decodeBytesPortableWAV() async throws {
        let x = tone(1600)
        let wav = WAV.encode(x, sampleRate: 16000, channels: 1)
        let mono = try await AudioIO.decode(bytes: wav, sampleRate: 16000)
        #expect(mono.count == x.count)
    }

    @Test func decodeResamplesToTargetRate() async throws {
        // Encode at 8 kHz, decode requesting 16 kHz: roughly 2x the samples.
        let x = tone(800, sr: 8000)
        let wav = WAV.encode(x, sampleRate: 8000, channels: 1)
        let mono = try await AudioIO.decode(bytes: wav, sampleRate: 16000)
        #expect(abs(Double(mono.count) - 1600) <= 4)
    }

    @Test func decodeFromFileRoundTrip() async throws {
        let x = tone(2000)
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("dal-audioio-test-\(UUID().uuidString).wav")
        try AudioIO.writeWAV(x, sampleRate: 16000, to: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        let mono = try await AudioIO.decode(path: url.path, sampleRate: 16000)
        #expect(mono.count == x.count)
    }
    #endif

    // MARK: extension-driven encoding

    @Test func formatInferredFromExtension() {
        #expect(AudioFileFormat.inferred(fromPathExtension: "wav") == .wav)
        #expect(AudioFileFormat.inferred(fromPathExtension: "WAV") == .wav)
        #expect(AudioFileFormat.inferred(fromPathExtension: "m4a") == .aac(bitRate: 128_000))
        #expect(AudioFileFormat.inferred(fromPathExtension: "mp4") == .aac(bitRate: 128_000))
        #expect(AudioFileFormat.inferred(fromPathExtension: "caf") == .pcm)
        #expect(AudioFileFormat.inferred(fromPathExtension: "aiff") == .pcm)
        #expect(AudioFileFormat.inferred(fromPathExtension: "opus") == nil)
    }

    #if !os(WASI)
    /// `.wav` must still produce a RIFF file byte-for-byte compatible with the
    /// portable encoder.
    @Test func writeWAVExtensionStaysRIFF() throws {
        let x = tone(2000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dal-fmt-\(UUID().uuidString).wav")
        try AudioIO.write(x, sampleRate: 16000, to: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        let head = try [UInt8](Data(contentsOf: url).prefix(12))
        #expect(Array(head[0..<4]) == Array("RIFF".utf8))
        #expect(Array(head[8..<12]) == Array("WAVE".utf8))
    }

    #if canImport(AVFoundation)
    /// The regression this whole change is about: an `.m4a` destination used to
    /// receive RIFF/WAVE bytes. It must now be a real MPEG-4 AAC file that
    /// decodes back to the same audio, and be far smaller than the PCM.
    @Test func m4aExtensionProducesAAC() async throws {
        // 48 kHz mono is what Clear emits, and the rate the explicit AAC bit
        // rate applies at.
        let sr = 48_000
        let x = tone(sr * 3, freq: 440, sr: Double(sr))
        let dir = FileManager.default.temporaryDirectory
        let m4a = dir.appendingPathComponent("dal-fmt-\(UUID().uuidString).m4a")
        let wav = dir.appendingPathComponent("dal-fmt-\(UUID().uuidString).wav")
        try AudioIO.write(x, sampleRate: sr, to: m4a.path)
        try AudioIO.write(x, sampleRate: sr, to: wav.path)
        defer {
            try? FileManager.default.removeItem(at: m4a)
            try? FileManager.default.removeItem(at: wav)
        }

        // Not a RIFF container: the old behaviour would have written one.
        let head = try [UInt8](Data(contentsOf: m4a).prefix(12))
        #expect(Array(head[0..<4]) != Array("RIFF".utf8))
        #expect(Array(head[4..<8]) == Array("ftyp".utf8), "expected an MPEG-4 box")

        // Lossy, so well under the 16-bit PCM. The requested bit rate is only a
        // hint to AVAudioFile, so this checks the order of magnitude rather than
        // an exact size.
        let aacSize = try FileManager.default.attributesOfItem(atPath: m4a.path)[.size] as! Int
        let wavSize = try FileManager.default.attributesOfItem(atPath: wav.path)[.size] as! Int
        #expect(aacSize < wavSize / 2)

        // And it is real audio: decodes back to about the same duration.
        let decoded = try await AudioIO.decode(path: m4a.path, sampleRate: Double(sr))
        #expect(abs(Double(decoded.count) - Double(x.count)) <= 4096)
    }
    #endif
    #endif

    @Test func stereoMixdown() throws {
        // Interleaved L/R: L = +0.5, R = -0.5 -> mono averages to 0.
        let interleaved = [Float](repeating: 0, count: 200).enumerated().map { i, _ in
            i % 2 == 0 ? Float(0.5) : Float(-0.5)
        }
        let wav = WAV.encode(interleaved, sampleRate: 16000, channels: 2)
        let pcm = try WAV.decode(wav)
        #expect(pcm.channels == 2)
        let mono = Resample.mixdownMono(pcm.samples, channels: 2)
        #expect(mono.count == 100)
        #expect(mono.allSatisfy { abs($0) < 1e-3 })
    }

    // !os(WASI) like every decode test above: on wasm, decode delegates to the
    // JS host (__DalAudioHost.decode), which the bare test harness never
    // installs. Not CoreML-gated: the portable path mixes down too, and Linux
    // should keep proving it.
    #if !os(WASI)
    @Test func fourteenChannelMixdown() async throws {
        // A real 14-channel field capture found two bugs in the Apple decode
        // path: beyond stereo AVAudioConverter has no downmix matrix and
        // silently returned channel 0 as the "mixdown", and the whole-file
        // single-buffer convert died with std::overflow_error once the file
        // was large enough (2.2 GB) to overflow AVFoundation's 32-bit byte
        // counts. The size half cannot be reproduced at fixture scale and is
        // fixed by chunking; this guards the correctness half. Channel c
        // carries a constant c/14, so the mono mixdown must be the average of
        // 0/14...13/14 = 6.5/14, not channel 0's flat zero.
        let sr = 16000
        let channels = 14
        var interleaved = [Float](repeating: 0, count: sr * channels)
        for f in 0..<sr { for c in 0..<channels { interleaved[f * channels + c] = Float(c) / 14 } }
        let wav = WAV.encode(interleaved, sampleRate: sr, channels: channels)
        let mono = try await AudioIO.decode(bytes: wav, sampleRate: Double(sr))
        #expect(mono.count == sr)
        let expected = Float(6.5) / 14
        #expect(mono.dropFirst(100).dropLast(100).allSatisfy { abs($0 - expected) < 2e-2 })
    }
    #endif



    #if canImport(AVFoundation)
    @Test(.longRunning) func multiGigabyteDecodeDoesNotOverflow() async throws {
        // The crash half of the 14-channel story (the mixdown half is above):
        // decoding a 2.2 GB capture died with std::overflow_error because the
        // whole-file convert allocated input buffers for every frame at once,
        // and frames x channels x 4 bytes crossed AVFoundation's 32-bit byte
        // counts. The threshold is real (about 2.15 GB of 16-bit source), so a
        // dense fixture cannot carry it; a sparse file of implicit zeros can,
        // at no disk cost. Apple-gated: the portable path reads whole files
        // into memory by design and never had the 32-bit limit.
        let channels = 14, sr = 48000
        let frames = 78_000_000  // x 14ch x 4B float32 = 4.37 GB > UInt32.max
        let dataSize = frames * channels * 2
        var hdr = [UInt8]()
        func u16(_ v: Int) { hdr.append(UInt8(v & 0xFF)); hdr.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ v: Int) { for s in 0..<4 { hdr.append(UInt8((v >> (8 * s)) & 0xFF)) } }
        hdr.append(contentsOf: "RIFF".utf8); u32(36 + dataSize); hdr.append(contentsOf: "WAVE".utf8)
        hdr.append(contentsOf: "fmt ".utf8); u32(16); u16(1); u16(channels); u32(sr)
        u32(sr * channels * 2); u16(channels * 2); u16(16)
        hdr.append(contentsOf: "data".utf8); u32(dataSize)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("dal-sparse-14ch-\(UUID().uuidString).wav").path
        FileManager.default.createFile(atPath: path, contents: Data(hdr))
        let fh = FileHandle(forWritingAtPath: path)!
        try fh.truncate(atOffset: UInt64(44 + dataSize))
        try fh.close()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let mono = try await AudioIO.decode(path: path, sampleRate: 16000)
        // 78M frames at 48 kHz resampled to 16 kHz: one third, unmixed length.
        #expect(mono.count == frames / 3)
        #expect(mono.prefix(1000).allSatisfy { $0 == 0 })
    }
    #endif
}
