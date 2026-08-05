import XCTest
import Foundation
import DesertAnt
import TestSupport
@testable import Clear

/// Clear's suite has two halves: the DSP front end, which is pure Swift and runs
/// everywhere with no model, and the end-to-end enhancement, which uses the
/// shared `ModelFixture` download like every other model's suite (no artifact is
/// committed) and is skipped where model-backed tests do not run.
final class ClearTests: XCTestCase {
    private func tone(_ n: Int, freq: Double = 220, sr: Double = 48_000, amp: Float = 0.3) -> [Float] {
        (0..<n).map { amp * Float(sin(2 * .pi * freq * Double($0) / sr)) }
    }

    private func snr(_ ref: [Float], _ rec: [Float]) -> Double {
        let n = min(ref.count, rec.count)
        var sig = 0.0, err = 0.0
        for i in 0..<n { sig += Double(ref[i]) * Double(ref[i]); let e = Double(ref[i]) - Double(rec[i]); err += e * e }
        return err > 0 ? 10 * log10(sig / err) : .infinity
    }

    // MARK: DSP (no model)

    // Validates the ported DFN STFT: analysis+synthesis reconstructs the signal
    // (Vorbis-window COLA identity), independent of the model.
    func testSTFTReconstruction() {
        let x = tone(48_000)
        let stft = ClearSTFT()
        let (re, im, frames) = stft.forward(x)
        XCTAssertGreaterThan(frames, 90)
        let y = stft.inverse(real: re, imag: im, nFrames: frames)
        XCTAssertGreaterThanOrEqual(y.count, x.count)
        // COLA identity holds on the interior; the first/last half-window lack
        // full overlap (the pipeline pads the tail, so this is edge-only).
        let pad = ClearDSP.fftSize
        let xi = Array(x[pad..<(x.count - pad)])
        let yi = Array(y[pad..<(x.count - pad)])
        XCTAssertGreaterThan(snr(xi, yi), 60)
    }

    func testFeaturesAreFinite() {
        let stft = ClearSTFT()
        let (re, im, frames) = stft.forward(tone(24_000))
        let (fe, fr, fi) = ClearFeatures.compute(real: re, imag: im, nFrames: frames)
        XCTAssertEqual(fe.count, frames * ClearDSP.nErb)
        XCTAssertEqual(fr.count, frames * ClearDSP.nDf)
        XCTAssertTrue((fe + fr + fi).allSatisfy { $0.isFinite })
    }

    // MARK: end to end (downloaded model)

    // Model-backed tests are wasm-guarded because the shared fixture does not
    // exist there (the store's filesystem and transport come from the JS host the
    // app installs), and skipped off iOS/Android by `requireModelBacked`.
#if !os(WASI)
    private func requireModelBacked() throws {
        try XCTSkipUnless(runsModelBackedTests, "model-backed tests do not run on iOS or Android")
    }

    /// The cached artifact for this platform: the Core ML directory on Apple,
    /// the LiteRT file elsewhere. Downloaded once per process by the fixture.
    private func enhancer() async throws -> Clear {
        let files = try await ModelFixture.files(ClearModel.self)
        do { return try Clear(modelPath: files.path(ClearModel.artifact)) }
        catch { throw XCTSkip("no runtime for \(ClearModel.artifact) on this host: \(error)") }
    }

    /// 2.5 s of tone plus deterministic noise at 48 kHz.
    private func noisyTone() -> [Float] {
        var x = tone(120_000)
        var seed: UInt64 = 1
        for i in 0..<x.count {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            x[i] += 0.15 * (Float(seed >> 40) / Float(1 << 24) - 0.5)
        }
        return x
    }

    func testEnhanceEndToEnd() async throws {
        try requireModelBacked()
        let clear = try await enhancer()
        let x = noisyTone()
        let result = try await clear.enhance(samples: x, sampleRate: 48_000,
                                             options: .init(strength: .full, targetLUFS: -19))
        XCTAssertEqual(result.sampleRate, 48_000)
        XCTAssertEqual(Double(result.samples.count), Double(x.count), accuracy: 480)
        XCTAssertTrue(result.samples.allSatisfy { $0.isFinite })
        var energy: Float = 0; for v in result.samples { energy += v * v }
        XCTAssertGreaterThan(energy, 0)                 // not silent
        XCTAssertNotNil(result.measuredLUFS)
    }

    /// The store path the SDK's own initializer takes: resolve the pinned model
    /// into the managed cache, then report it as available offline.
    func testResolvesThroughTheModelStore() async throws {
        try requireModelBacked()
        _ = try await ModelFixture.files(ClearModel.self)
        // Availability is per instance now (LoadedModel owns it), so ask one.
        XCTAssertTrue(Clear().isDownloaded())
    }

    /// The file-in/file-out path (Apple/Linux): decode any audio file, enhance,
    /// and write a 48 kHz WAV. Uses the core's AudioIO for both ends, so this
    /// also covers the WAV encode the SDK hands users.
    #if canImport(Foundation) && !os(Android)
    func testEnhanceFileToFile() async throws {
        try requireModelBacked()
        let clear = try await enhancer()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clear-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let input = dir.appendingPathComponent("in.wav")
        let output = dir.appendingPathComponent("out.wav")
        try AudioIO.writeWAV(noisyTone(), sampleRate: 48_000, to: input.path)

        let result = try await clear.enhance(path: input.path, to: output.path)
        XCTAssertEqual(result.sampleRate, 48_000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        // The written file decodes back to the enhanced signal.
        let decoded = try await AudioIO.decode(path: output.path, sampleRate: 48_000)
        XCTAssertEqual(Double(decoded.count), Double(result.samples.count), accuracy: 480)
        XCTAssertTrue(decoded.contains { $0 != 0 })
    }
    #endif

    /// The bindings' audio payload contract (`dal_run_audio`): options in and
    /// samples out, decoded with the same reader a host uses.
    func testBindingAudioPayloadRoundTrip() async throws {
        try requireModelBacked()
        let clear = try await enhancer()
        var options = FFIWriter()
        options.f64(1.0)        // strength
        options.f64(.nan)       // targetLUFS: mastering disabled
        options.f64(-1.0)       // peak ceiling
        options.f64(12)         // max gain
        guard let payload = await clear.run(audio: noisyTone(), sampleRate: 48_000,
                                            options: FFIReader(options.bytes)) else {
            return XCTFail("the audio binding returned no payload")
        }
        var reader = FFIReader(payload)
        let samples = reader.f32Array()
        XCTAssertFalse(samples.isEmpty)
        XCTAssertEqual(reader.f64(), 48_000)            // sample rate
        XCTAssertGreaterThan(reader.f64(), 0)           // duration
        XCTAssertGreaterThan(reader.f64(), 0)           // processing time
        XCTAssertTrue(reader.f64().isNaN)               // measured LUFS: none, mastering off
    }
#endif
}
