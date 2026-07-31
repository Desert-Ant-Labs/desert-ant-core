import XCTest
import Foundation
@testable import AudioIO

final class AudioIOTests: XCTestCase {
    private func tone(_ n: Int, freq: Double = 440, sr: Double = 16000) -> [Float] {
        (0..<n).map { Float(0.5 * sin(2 * .pi * freq * Double($0) / sr)) }
    }

    func testWAVRoundTrip16Bit() throws {
        let x = tone(4000)
        let bytes = WAV.encode(x, sampleRate: 16000, channels: 1)
        let pcm = try WAV.decode(bytes)
        XCTAssertEqual(pcm.sampleRate, 16000)
        XCTAssertEqual(pcm.channels, 1)
        XCTAssertEqual(pcm.samples.count, x.count)
        // 16-bit quantization error is bounded by ~1/32768.
        var maxErr: Float = 0
        for i in 0..<x.count { maxErr = max(maxErr, abs(x[i] - pcm.samples[i])) }
        XCTAssertLessThan(maxErr, 1e-3)
    }

    // AudioIO.decode / writeWAV route through the platform backend: the
    // AVFoundation/portable-WAV path on Apple/Linux, but the JS host on wasm
    // (which isn't installed in the Swift test harness) and a filesystem the
    // WASI sandbox lacks. The wasm decode path is covered by js/test/audio.test.mjs
    // (installAudioHost). These exercise the native/portable path only.
    #if !os(WASI)
    func testDecodeBytesPortableWAV() async throws {
        let x = tone(1600)
        let wav = WAV.encode(x, sampleRate: 16000, channels: 1)
        let mono = try await AudioIO.decode(bytes: wav, sampleRate: 16000)
        XCTAssertEqual(mono.count, x.count)
    }

    func testDecodeResamplesToTargetRate() async throws {
        // Encode at 8 kHz, decode requesting 16 kHz: roughly 2x the samples.
        let x = tone(800, sr: 8000)
        let wav = WAV.encode(x, sampleRate: 8000, channels: 1)
        let mono = try await AudioIO.decode(bytes: wav, sampleRate: 16000)
        XCTAssertEqual(Double(mono.count), 1600, accuracy: 4)
    }

    func testDecodeFromFileRoundTrip() async throws {
        let x = tone(2000)
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("dal-audioio-test-\(UUID().uuidString).wav")
        try AudioIO.writeWAV(x, sampleRate: 16000, to: url.path)
        defer { try? FileManager.default.removeItem(at: url) }
        let mono = try await AudioIO.decode(path: url.path, sampleRate: 16000)
        XCTAssertEqual(mono.count, x.count)
    }
    #endif

    func testStereoMixdown() throws {
        // Interleaved L/R: L = +0.5, R = -0.5 -> mono averages to 0.
        let interleaved = [Float](repeating: 0, count: 200).enumerated().map { i, _ in
            i % 2 == 0 ? Float(0.5) : Float(-0.5)
        }
        let wav = WAV.encode(interleaved, sampleRate: 16000, channels: 2)
        let pcm = try WAV.decode(wav)
        XCTAssertEqual(pcm.channels, 2)
        let mono = Resample.mixdownMono(pcm.samples, channels: 2)
        XCTAssertEqual(mono.count, 100)
        XCTAssertTrue(mono.allSatisfy { abs($0) < 1e-3 })
    }
}
